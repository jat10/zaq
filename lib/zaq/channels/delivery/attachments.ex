defmodule Zaq.Channels.Delivery.Attachments do
  @moduledoc """
  Plans attachment delivery from Record metadata and prepares bytes during execution.

  Plans retain stable original indices, never a second source collection. Execution
  redeems each required Record once with trusted identity, checks actual fixed-group
  limits, and prepares exact provider payloads before any upload or publication.
  Size drift is accepted only when actual payloads fit; execution never regroups.
  Source files are preserved and no temporary files are created.
  """

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Channels.Delivery.{Error, Plan}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @doc "Builds a metadata-only plan; empty selections return unchanged, including selection errors."
  @spec build_plan(Outgoing.t(), module(), map()) ::
          {:ok, Outgoing.t()} | {:error, Error.t()}
  def build_plan(%Outgoing{delivery: %{attachments: []}} = outgoing, _bridge, _connection),
    do: {:ok, outgoing}

  def build_plan(%Outgoing{delivery: %{attachments: attachments}}, _bridge, _connection)
      when not is_list(attachments), do: {:error, delivery_error(:invalid_attachments)}

  def build_plan(%Outgoing{body: body}, _bridge, _connection) when not is_binary(body),
    do: {:error, delivery_error(:invalid_postable)}

  def build_plan(%Outgoing{} = outgoing, bridge, connection) do
    case requirements(bridge, outgoing, connection) do
      {:ok, requirements} ->
        {attachments, failures} = metadata(outgoing.delivery.attachments)
        failures = selection_failures(outgoing.delivery.error) ++ failures
        {batches, omitted} = pack(attachments, &metadata_group(&1, requirements))
        failures = failures ++ omitted

        with :ok <- preparation_gate(requirements.failure_policy, failures) do
          message_id = existing_message(outgoing, bridge, connection)
          {groups, steps} = plan_groups(batches, outgoing, requirements, message_id)

          plan = %Plan{
            failure_policy: requirements.failure_policy,
            requirements: requirements,
            placement: placement(requirements, outgoing),
            groups: groups,
            steps: steps,
            preparation_failures: failures
          }

          {:ok, put_in(outgoing.delivery.plan, plan)}
        end

      {:error, error, :continue} ->
        failures =
          outgoing.delivery.attachments
          |> Enum.with_index()
          |> Enum.map(fn {_, index} -> planning_failure(index, error) end)

        {groups, steps} = plan_groups([], outgoing, nil, nil)

        plan = %Plan{
          failure_policy: :continue,
          placement: placement(nil, outgoing),
          groups: groups,
          steps: steps,
          preparation_failures: failures
        }

        {:ok, put_in(outgoing.delivery.plan, plan)}

      {:error, error, :abort} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp requirements(bridge, outgoing, connection) do
    if Code.ensure_loaded?(bridge) and function_exported?(bridge, :transport_requirements, 2),
      do: bridge.transport_requirements(outgoing, connection),
      else: TransportRequirements.validate(nil)
  end

  @doc "Plans a malformed-input text notice using the bridge's resolved policy."
  def build_failure_plan(outgoing, error, bridge, connection) do
    case requirements(bridge, outgoing, connection) do
      {:ok, %{failure_policy: :continue}} -> failure_notice(outgoing, error)
      {:error, _, :continue} -> failure_notice(outgoing, error)
      _ -> {:error, error}
    end
  end

  defp failure_notice(outgoing, error) do
    notice = %{
      outgoing
      | body: Enum.join([outgoing.body, error.message], "\n\n"),
        delivery: %Outgoing.Delivery{},
        metadata:
          Map.drop(outgoing.metadata || %{}, [:on_reply, "on_reply", :html_body, "html_body"])
    }

    {groups, steps} = plan_groups([], notice, nil, nil)
    groups = Enum.map(groups, &Map.merge(&1, %{canonical_body: outgoing.body, notice?: true}))

    plan = %Plan{
      failure_policy: :continue,
      placement: placement(nil, outgoing),
      groups: groups,
      steps: steps,
      preparation_failures: [planning_failure(nil, error)]
    }

    {:ok, put_in(notice.delivery.plan, plan)}
  end

  defp selection_failures(nil), do: []
  defp selection_failures(reason), do: [planning_failure(nil, delivery_error(reason))]

  defp metadata(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {record, index}, {accepted, failures} ->
      case metadata_attachment(record, index) do
        {:ok, attachment} ->
          {accepted ++ [attachment], failures}

        {:error, reason} ->
          {accepted, failures ++ [planning_failure(index, delivery_error(reason))]}
      end
    end)
  end

  defp metadata_attachment(
         %Record{id: id, kind: :file, size: size, attributes: attrs} = record,
         index
       )
       when is_binary(id) and id != "" and is_map(attrs) and
              (is_nil(size) or (is_integer(size) and size >= 0)) do
    with :ok <- validate_metadata(record), do: {:ok, %{attachment_index: index, size: size || 0}}
  end

  defp metadata_attachment(_record, _index), do: {:error, :invalid_attachment}

  defp metadata_group(attachments, requirements) do
    size = Enum.sum(Enum.map(attachments, & &1.size))

    cond do
      length(attachments) > requirements.max_attachments_per_message ->
        {:error, :message_too_large}

      Enum.any?(attachments, &(not within_limit?(&1.size, requirements.max_attachment_bytes))) ->
        {:error, :file_too_large}

      requirements.transfer_mode == :upload_then_publish and
          Enum.any?(
            attachments,
            &(not within_limit?(&1.size, requirements.max_upload_request_bytes))
          ) ->
        {:error, :upload_request_too_large}

      not within_limit?(size, requirements.max_attachment_bytes_per_message) ->
        {:error, :message_too_large}

      not within_limit?(size, requirements.max_encoded_message_bytes) ->
        {:error, :message_too_large}

      true ->
        {:ok, nil}
    end
  end

  defp pack(attachments, prepare) do
    {batches, current, failures} =
      Enum.reduce(attachments, {[], [], []}, fn attachment, acc ->
        pack_attachment(attachment, prepare, acc)
      end)

    {if(current == [], do: batches, else: batches ++ [current]), failures}
  end

  defp pack_attachment(attachment, prepare, {batches, current, failures}) do
    case prepare.(current ++ [attachment]) do
      {:ok, _} ->
        {batches, current ++ [attachment], failures}

      {:error, _} when current != [] ->
        pack_attachment(attachment, prepare, {batches ++ [current], [], failures})

      {:error, reason} ->
        {batches, [],
         failures ++
           [planning_failure(attachment.attachment_index, normalize_planning_error(reason))]}
    end
  end

  defp existing_message(outgoing, bridge, connection) do
    if function_exported?(bridge, :existing_message, 2),
      do: bridge.existing_message(outgoing, connection)
  end

  defp plan_groups([], outgoing, requirements, message_id),
    do: plan_groups([[]], outgoing, requirements, message_id)

  defp plan_groups(batches, outgoing, requirements, message_id) do
    batches
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {attachments, id}, {groups, steps} ->
      uploads = upload_steps(attachments, id, requirements)

      refs = Enum.map(attachments, & &1.attachment_index)
      operation = if groups == [] and not is_nil(message_id), do: :edit, else: :send

      step = %Step{
        id: {operation, id},
        operation: operation,
        group_id: id,
        attachment_refs: refs,
        depends_on: Enum.map(uploads, & &1.id),
        message_ref: if(operation == :edit, do: {:existing, message_id})
      }

      {groups ++ [%{id: id, attachment_refs: refs, body: outgoing.body}],
       steps ++ uploads ++ [step]}
    end)
  end

  defp upload_steps(attachments, group_id, %{transfer_mode: :upload_then_publish} = requirements) do
    {batches, _failures} =
      pack(attachments, &upload_batch(&1, requirements.max_upload_request_bytes))

    batches
    |> Enum.with_index()
    |> Enum.map(fn {batch, batch_id} ->
      %Step{
        id: {:upload, group_id, batch_id},
        operation: :upload,
        group_id: group_id,
        attachment_refs: Enum.map(batch, & &1.attachment_index)
      }
    end)
  end

  defp upload_steps(_attachments, _group_id, _requirements), do: []

  defp upload_batch(attachments, ceiling) do
    if within_limit?(Enum.sum(Enum.map(attachments, & &1.size)), ceiling),
      do: {:ok, nil},
      else: {:error, :upload_request_too_large}
  end

  defp placement(nil, %{thread_id: id}) when not is_nil(id), do: :threaded
  defp placement(%{supports_threads: true}, _outgoing), do: :threaded
  defp placement(_requirements, _outgoing), do: :independent

  @doc """
  Acquires and checks a completed plan without changing it or its source Outgoing.

  Returns prepared attachments keyed by original index, prepared steps and safe
  failures under the plan's policy. Lazy files require the connection's trusted
  context. Only declared standard base64 is decoded, accepting whitespace and
  optional padding; absent or `"binary"` encoding preserves bytes verbatim.
  """
  @spec prepare_execution(Outgoing.t(), module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_execution(outgoing, bridge, connection) do
    plan = outgoing.delivery.plan
    refs = plan.groups |> Enum.flat_map(& &1.attachment_refs) |> Enum.uniq()

    {attachments, failures, acquisition_error} =
      Enum.reduce(refs, {%{}, plan.preparation_failures, nil}, fn index,
                                                                  {prepared, failures,
                                                                   first_error} ->
        record = Enum.at(outgoing.delivery.attachments, index)

        context =
          Map.get(connection, :trusted_context, %{})
          |> TrustedContext.normalize()
          |> Map.from_struct()
          |> Map.merge(Map.take(connection, [:node_router]))

        with {:ok, attachment} <- acquire_for_execution(record, context),
             true <-
               is_nil(plan.requirements) or
                 within_limit?(attachment.size, plan.requirements.max_attachment_bytes) do
          {Map.put(prepared, index, Map.put(attachment, :attachment_index, index)), failures,
           first_error}
        else
          false ->
            {prepared,
             failures ++ [planning_failure(index, normalize_planning_error(:file_too_large))],
             first_error || normalize_planning_error(:file_too_large)}

          {:error, reason} ->
            {prepared, failures ++ [planning_failure(index, normalize_planning_error(reason))],
             first_error || normalize_planning_error(reason)}
        end
      end)

    {prepared_steps, errors, failures} =
      Enum.reduce(plan.steps, {%{}, %{}, failures}, fn step, {prepared, errors, failures} ->
        selected =
          step.attachment_refs
          |> Enum.filter(&Map.has_key?(attachments, &1))
          |> Enum.map(&Map.fetch!(attachments, &1))

        case prepare_operation(step, selected, outgoing, bridge, connection, plan.requirements) do
          {:ok, payload} ->
            {Map.put(prepared, step.id, payload), errors, failures}

          {:error, reason} ->
            error = normalize_planning_error(reason)
            omitted = Enum.map(selected, &planning_failure(&1.attachment_index, error))
            {prepared, Map.put(errors, step.id, error), failures ++ omitted}
        end
      end)

    with :ok <- acquisition_gate(plan.failure_policy, acquisition_error),
         :ok <- preparation_gate(plan.failure_policy, failures) do
      {:ok,
       %{
         attachments: attachments,
         prepared_steps: prepared_steps,
         preparation_errors: errors,
         preparation_failures: Enum.uniq(failures)
       }}
    end
  end

  defp acquire_for_execution(record, context) do
    prepare_record(record, context)
  rescue
    _ -> {:error, :attachment_preparation_exception}
  catch
    _, _ -> {:error, :attachment_preparation_exit}
  end

  defp prepare_operation(step, attachments, outgoing, bridge, connection, requirements) do
    prepare_step(step, attachments, outgoing, bridge, connection, requirements)
  rescue
    _ -> {:error, :attachment_preparation_exception}
  catch
    _, _ -> {:error, :attachment_preparation_exit}
  end

  defp acquisition_gate(:abort, %Error{} = error), do: {:error, error}
  defp acquisition_gate(_policy, _error), do: :ok

  defp prepare_step(%{operation: :upload}, [], _outgoing, _bridge, _connection, _requirements),
    do: {:ok, nil}

  defp prepare_step(
         %{operation: :upload},
         attachments,
         _outgoing,
         bridge,
         connection,
         requirements
       ) do
    with {:ok, payload} <- bridge.prepare_upload_request(attachments, connection),
         :ok <-
           encoded_size(
             payload,
             if(requirements, do: requirements.max_upload_request_bytes, else: :not_applicable),
             :upload_request_too_large
           ),
         do: {:ok, payload}
  end

  defp prepare_step(step, attachments, outgoing, bridge, connection, requirements) do
    limit =
      if requirements, do: requirements.max_attachment_bytes_per_message, else: :not_applicable

    with true <- within_limit?(Enum.sum(Enum.map(attachments, & &1.size)), limit),
         {:ok, payload} <-
           prepare_message(step, outgoing, attachments, bridge, connection, requirements) do
      {:ok, payload}
    else
      false -> {:error, :message_too_large}
      error -> error
    end
  end

  defp prepare_message(step, outgoing, attachments, bridge, connection, requirements) do
    ceiling = if requirements, do: requirements.max_encoded_message_bytes, else: :not_applicable

    cond do
      function_exported?(bridge, :prepare_delivery_message, 3) ->
        with {:ok, payload} <-
               bridge.prepare_delivery_message(
                 outgoing,
                 attachments,
                 Map.put(connection, :delivery_group_id, step.group_id)
               ),
             :ok <- encoded_size(payload, ceiling, :message_too_large),
             do: {:ok, payload}

      ceiling == :not_applicable ->
        {:ok, nil}

      true ->
        {:error, :invalid_prepared_message}
    end
  end

  defp encoded_size(%{encoded_bytes: bytes}, limit, reason) when is_integer(bytes) and bytes >= 0,
    do: if(within_limit?(bytes, limit), do: :ok, else: {:error, reason})

  defp encoded_size(_payload, _limit, _reason), do: {:error, :invalid_prepared_message}

  defp within_limit?(_size, :not_applicable), do: true
  defp within_limit?(size, limit), do: is_integer(limit) and size <= limit

  defp preparation_gate(:abort, [%{stage: :selection} | _]),
    do: {:error, delivery_error(:invalid_attachment_selection)}

  defp preparation_gate(:abort, [failure | _]),
    do:
      {:error,
       %Error{
         reason: {:attachment_preparation_failed, failure.reason},
         message: failure.reason,
         stage: failure.stage,
         delivery: :not_sent
       }}

  defp preparation_gate(_policy, _failures), do: :ok

  defp planning_failure(index, error),
    do: %{
      attachment_index: index,
      stage: error.stage,
      delivery: error.delivery,
      reason: error.message
    }

  defp normalize_planning_error(%Error{} = error), do: error

  defp normalize_planning_error(reason)
       when reason in [:file_too_large, :message_too_large, :upload_request_too_large],
       do: %Error{
         reason: reason,
         message: "The attachment cannot fit the connector's delivery limits.",
         stage: :preparation,
         delivery: :not_sent
       }

  defp normalize_planning_error(reason), do: delivery_error(reason)

  @doc "Maps shared attachment selection and preparation failures before transport."
  @spec delivery_error(term()) :: Error.t()
  def delivery_error(:invalid_attachment_selection) do
    %Error{
      reason: :invalid_attachment_selection,
      message: "The requested attachments could not be attached.",
      stage: :selection,
      delivery: :not_sent
    }
  end

  def delivery_error(reason) do
    %Error{
      reason: reason,
      message: preparation_message(reason),
      stage: :preparation,
      delivery: :not_sent
    }
  end

  defp preparation_message(:invalid_attachment_base64),
    do: "The attachment contains invalid Base64 content."

  defp preparation_message(:invalid_attachment_encoding),
    do: "The attachment encoding is not supported."

  defp preparation_message(:email_encoding_failed), do: "The email could not be encoded."

  defp preparation_message(:invalid_attachment_metadata),
    do: "The attachment filename or content type is invalid."

  defp preparation_message(reason)
       when reason in [:invalid_attachments, :invalid_attachment, :invalid_attachment_content],
       do: "The attachment data is invalid."

  defp preparation_message(_reason), do: "The attachment content could not be accessed."

  defp prepare_record(%Record{id: id, kind: :file, attributes: attrs} = record, context)
       when is_binary(id) and id != "" and is_map(attrs) do
    with :ok <- validate_metadata(record),
         {:ok, materialized} <- acquire(record, context),
         :ok <- validate_metadata(materialized),
         {:ok, content} <- decode_content(materialized) do
      {:ok,
       %{
         content: content,
         name: materialized.name || record.name || "attachment",
         mime_type: materialized.mime_type || record.mime_type || "application/octet-stream",
         size: byte_size(content)
       }}
    end
  end

  defp prepare_record(_record, _context), do: {:error, :invalid_attachment}

  defp acquire(%Record{content: content} = record, _context) when is_binary(content),
    do: {:ok, record}

  defp acquire(%Record{content: nil, materialization_handle: handle}, context)
       when is_binary(handle) and handle != "" do
    Materialization.materialize(handle, context, "Attachment preparation failed")
    |> case do
      {:ok, %{record: %Record{kind: :file, attributes: attrs} = record}} when is_map(attrs) ->
        {:ok, record}

      {:ok, _} ->
        {:error, :invalid_attachment}

      {:error, _} = error ->
        error
    end
  end

  defp acquire(%Record{content: nil}, _context), do: {:error, :attachment_content_unavailable}
  defp acquire(_record, _context), do: {:error, :invalid_attachment_content}

  defp decode_content(%Record{content: content, attributes: attrs}) when is_binary(content) do
    case Map.get(attrs, "encoding", Map.get(attrs, :encoding)) do
      "base64" ->
        case Jido.Exec.run(DecodeBase64, %{data: content, variant: "standard"}, %{}) do
          {:ok, %{decoded: bytes}} -> {:ok, bytes}
          {:error, _reason} -> {:error, :invalid_attachment_base64}
        end

      encoding when encoding in [nil, "binary"] ->
        {:ok, content}

      _ ->
        {:error, :invalid_attachment_encoding}
    end
  end

  defp decode_content(_record), do: {:error, :invalid_attachment_content}

  defp validate_metadata(%Record{name: name, mime_type: mime_type}) do
    if valid_name?(name) and valid_mime?(mime_type),
      do: :ok,
      else: {:error, :invalid_attachment_metadata}
  end

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name) and name != "" do
    String.valid?(name) and name not in [".", ".."] and
      not String.match?(name, ~r/[\x00-\x1f\x7f\/\\]/u)
  end

  defp valid_name?(_name), do: false

  defp valid_mime?(nil), do: true

  defp valid_mime?(mime_type) when is_binary(mime_type) do
    String.match?(mime_type, ~r/\A[A-Za-z0-9!#$&^_.+\-]+\/[A-Za-z0-9!#$&^_.+\-]+\z/)
  end

  defp valid_mime?(_mime_type), do: false
end
