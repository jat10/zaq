defmodule Zaq.Channels.DeliveryFiles do
  @moduledoc """
  Prepares explicitly supplied file Records for delivery.

  Existing binary content is used directly. Lazy Records are redeemed through the
  registered materialization handlers with normalized trusted identity; returned
  name and MIME describe the acquired representation when supplied. Only raw
  bytes and safe transport metadata reach the consumer; source paths, credentials
  and handles are never forwarded or retained. No temporary files are created or
  original source files deleted. Materialization still acquires whole content.

  `build_plan/3` resolves the selected bridge's requirements before acquisition,
  groups files in order and chooses exact upload requests. It applies preparation
  policy without performing transport effects; `DeliveryExecutor` owns execution.
  The first surviving publication group may edit an existing streamed message,
  retaining original group and attachment indices when earlier groups are omitted.
  """

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Channels.{DeliveryError, DeliveryPlan, FileRequirements}
  alias Zaq.Channels.DeliveryPlan.Step
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @type prepared :: %{
          optional(:attachment_index) => non_neg_integer(),
          content: binary(),
          name: String.t(),
          mime_type: String.t(),
          size: non_neg_integer()
        }

  @doc """
  Builds one private delivery plan after requirements and all acquisition finish.

  Ordinary text returns unchanged without calling the bridge. Planned files keep
  original indices; exact bridge preparation determines message and request fits.
  This function performs no uploads or publication. Direct callers without an
  explicit policy retain fail-fast preparation semantics.
  """
  @spec build_plan(Outgoing.t(), module(), map()) ::
          {:ok, Outgoing.t()} | {:error, DeliveryError.t()}
  def build_plan(
        %Outgoing{attachments: [], attachment_error: nil} = outgoing,
        _bridge,
        _connection
      ),
      do: {:ok, outgoing}

  def build_plan(%Outgoing{attachments: attachments}, _bridge, _connection)
      when not is_list(attachments),
      do: {:error, delivery_error(:invalid_attachments)}

  def build_plan(%Outgoing{body: body}, _bridge, _connection) when not is_binary(body),
    do:
      {:error,
       %DeliveryError{
         reason: :invalid_postable,
         message: "The message body is invalid.",
         stage: :preparation,
         delivery: :not_sent
       }}

  def build_plan(%Outgoing{} = outgoing, bridge, connection) do
    policy = Map.get(connection, :attachment_failure_policy, :abort)

    connection =
      connection
      |> Map.put(:delivery_channel_id, outgoing.channel_id)
      |> Map.put(:delivery_provider, outgoing.provider)

    failures = selection_failures(outgoing.attachment_error)

    with :ok <- valid_policy(policy),
         :ok <- preparation_gate(policy, failures),
         {:ok, requirements, files, failures} <-
           plan_files(outgoing, bridge, connection, failures),
         {:ok, plan} <-
           assemble_plan(outgoing, bridge, connection, requirements, files, failures, policy) do
      {:ok, %{outgoing | delivery_plan: plan}}
    end
  end

  defp valid_policy(policy) when policy in [:continue, :abort], do: :ok
  defp valid_policy(_policy), do: {:error, delivery_error(:invalid_attachment_failure_policy)}

  @doc "Plans a legacy malformed-input notice through the same preparation and execution contract."
  @spec build_failure_plan(Outgoing.t(), DeliveryError.t(), module(), map()) ::
          {:ok, Outgoing.t()} | {:error, DeliveryError.t()}
  def build_failure_plan(outgoing, error, bridge, connection) do
    case Map.get(connection, :attachment_failure_policy, :abort) do
      :continue ->
        notice = %{
          outgoing
          | attachments: [],
            attachment_error: nil,
            delivery_plan: nil,
            body: Enum.join(Enum.reject([outgoing.body, error.message], &(&1 == "")), "\n\n"),
            metadata:
              Map.drop(outgoing.metadata || %{}, [:on_reply, "on_reply", :html_body, "html_body"])
        }

        with {:ok, plan} <-
               assemble_plan(
                 notice,
                 bridge,
                 connection,
                 nil,
                 [],
                 [planning_failure(nil, error)],
                 :continue
               ) do
          groups =
            Enum.map(plan.groups, &Map.merge(&1, %{canonical_body: outgoing.body, notice?: true}))

          {:ok, %{notice | delivery_plan: %{plan | groups: groups}}}
        end

      _ ->
        {:error, error}
    end
  end

  defp selection_failures(nil), do: []
  defp selection_failures(reason), do: [planning_failure(nil, delivery_error(reason))]

  defp plan_files(%Outgoing{attachments: []}, _bridge, _connection, failures),
    do: {:ok, nil, [], failures}

  defp plan_files(outgoing, bridge, connection, failures) do
    with {:ok, requirements} <- requirements(bridge, outgoing, connection),
         {:ok, files, preparation_failures} <-
           prepare(
             outgoing.attachments,
             Map.get(connection, :trusted_context, %{}),
             Keyword.put(
               Map.to_list(Map.take(connection, [:node_router])),
               :attachment_failure_policy,
               Map.get(connection, :attachment_failure_policy, :abort)
             )
           ) do
      {:ok, requirements, files, failures ++ preparation_failures}
    else
      {:error, reason} ->
        error = normalize_planning_error(reason)

        omitted =
          outgoing.attachments
          |> Enum.with_index()
          |> Enum.map(fn {_record, index} -> planning_failure(index, error) end)

        case Map.get(connection, :attachment_failure_policy, :abort) do
          :abort -> {:error, error}
          :continue -> {:ok, nil, [], failures ++ omitted}
        end
    end
  end

  defp requirements(bridge, outgoing, connection) do
    if Code.ensure_loaded?(bridge) and function_exported?(bridge, :file_requirements, 2) do
      with {:ok, requirements} <- bridge.file_requirements(outgoing, connection),
           :ok <- FileRequirements.validate(requirements),
           :ok <- preparation_callbacks(bridge, requirements),
           do: {:ok, requirements}
    else
      FileRequirements.validate(nil)
    end
  end

  defp preparation_callbacks(bridge, requirements) do
    upload? =
      requirements.transfer_mode != :upload_then_publish or
        function_exported?(bridge, :prepare_upload_request, 2)

    message? =
      requirements.max_encoded_message_bytes == :not_applicable or
        function_exported?(bridge, :prepare_delivery_message, 3)

    if upload? and message?, do: :ok, else: FileRequirements.validate(nil)
  end

  defp assemble_plan(outgoing, bridge, connection, requirements, files, failures, policy) do
    {batches, group_failures} =
      pack(files, fn candidate, group_id ->
        prepare_message_group(
          candidate,
          outgoing,
          bridge,
          Map.put(connection, :delivery_group_id, group_id),
          requirements
        )
      end)

    {groups, steps, upload_failures} =
      plan_groups(batches, outgoing, bridge, connection, requirements)

    failures = failures ++ group_failures ++ upload_failures

    with :ok <- preparation_gate(policy, failures),
         {:ok, groups, steps} <-
           ensure_text_group(groups, steps, outgoing, bridge, connection, requirements, failures) do
      {:ok,
       %DeliveryPlan{
         failure_policy: policy,
         placement: placement(requirements, outgoing),
         root_message_id: outgoing.thread_id,
         requirements: requirements,
         files: Map.new(files, &{&1.attachment_index, &1}),
         groups: groups,
         steps: steps,
         preparation_failures: failures
       }}
    end
  end

  defp placement(nil, %{thread_id: id}) when not is_nil(id), do: :threaded
  defp placement(%{supports_threads: true}, _outgoing), do: :threaded
  defp placement(_requirements, _outgoing), do: :independent

  defp prepare_message_group(files, outgoing, bridge, connection, requirements) do
    cond do
      length(files) > requirements.max_files_per_message ->
        {:error, :message_too_large}

      Enum.any?(files, &(not within_limit?(&1.size, requirements.max_file_bytes))) ->
        {:error, :file_too_large}

      not within_limit?(
        Enum.sum(Enum.map(files, & &1.size)),
        requirements.max_attachment_bytes_per_message
      ) ->
        {:error, :message_too_large}

      requirements.max_encoded_message_bytes == :not_applicable ->
        {:ok, nil}

      true ->
        prepare_encoded_message(
          outgoing,
          files,
          bridge,
          connection,
          requirements.max_encoded_message_bytes
        )
    end
  end

  defp prepare_encoded_message(outgoing, files, bridge, connection, ceiling) do
    with {:ok, %{encoded_bytes: size} = prepared} <-
           bridge.prepare_delivery_message(outgoing, files, connection),
         true <- is_integer(size) and size >= 0 and within_limit?(size, ceiling) do
      {:ok, prepared}
    else
      false -> {:error, :message_too_large}
      {:error, _} = error -> error
      _ -> {:error, :invalid_prepared_message}
    end
  end

  defp within_limit?(_size, :not_applicable), do: true
  defp within_limit?(size, limit), do: is_integer(limit) and size <= limit

  # Keep the last accepted representation: the bytes measured are the bytes sent.
  defp pack(files, prepare) do
    {batches, current, prepared, failures} =
      Enum.reduce(files, {[], [], nil, []}, fn file, accumulator ->
        pack_file(file, prepare, accumulator)
      end)

    batches =
      if current == [], do: batches, else: batches ++ [%{files: current, prepared: prepared}]

    {batches, failures}
  end

  defp pack_file(file, prepare, {batches, current, prepared, failures}) do
    case prepare.(current ++ [file], length(batches)) do
      {:ok, candidate} ->
        {batches, current ++ [file], candidate, failures}

      {:error, _reason} when current != [] ->
        pack_file(
          file,
          prepare,
          {batches ++ [%{files: current, prepared: prepared}], [], nil, failures}
        )

      {:error, reason} ->
        {batches, [], nil,
         failures ++ [planning_failure(file.attachment_index, normalize_planning_error(reason))]}
    end
  end

  defp plan_groups(batches, outgoing, bridge, connection, requirements) do
    batches
    |> Enum.with_index()
    |> Enum.reduce({[], [], []}, fn {batch, group_id}, {groups, steps, failures} ->
      {upload_steps, eligible, omitted} =
        upload_steps(batch.files, group_id, bridge, connection, requirements)

      refs = Enum.map(eligible, & &1.attachment_index)
      group = %{id: group_id, file_refs: refs, prepared: batch.prepared, body: outgoing.body}
      operation = publication_operation(outgoing, groups == [], requirements)

      step = %Step{
        id: {operation, group_id},
        operation: operation,
        group_id: group_id,
        file_refs: refs,
        message_ref: existing_message(outgoing, operation),
        depends_on: Enum.map(upload_steps, & &1.id),
        prepared: batch.prepared
      }

      if refs == [],
        do: {groups, steps, failures ++ omitted},
        else: {groups ++ [group], steps ++ upload_steps ++ [step], failures ++ omitted}
    end)
  end

  defp upload_steps(
         files,
         group_id,
         bridge,
         connection,
         %{transfer_mode: :upload_then_publish} = requirements
       ) do
    {batches, failures} =
      pack(files, fn candidate, _batch_id ->
        with {:ok, %{encoded_bytes: size} = prepared} <-
               bridge.prepare_upload_request(candidate, connection),
             true <-
               is_integer(size) and size >= 0 and
                 within_limit?(size, requirements.max_upload_request_bytes) do
          {:ok, prepared}
        else
          false -> {:error, :upload_request_too_large}
          {:error, _} = error -> error
          _ -> {:error, :invalid_prepared_upload}
        end
      end)

    steps =
      batches
      |> Enum.with_index()
      |> Enum.map(fn {batch, index} ->
        %Step{
          id: {:upload, group_id, index},
          operation: :upload,
          group_id: group_id,
          file_refs: Enum.map(batch.files, & &1.attachment_index),
          prepared: batch.prepared
        }
      end)

    {steps, Enum.flat_map(batches, & &1.files), failures}
  end

  defp upload_steps(files, _group_id, _bridge, _connection, _requirements), do: {[], files, []}

  defp publication_operation(outgoing, true, %{supports_attachment_edits: true}) do
    if message_id(outgoing), do: :edit, else: :send
  end

  defp publication_operation(_outgoing, _first_group?, _requirements), do: :send
  defp existing_message(outgoing, :edit), do: {:existing, message_id(outgoing)}
  defp existing_message(_outgoing, _operation), do: nil

  defp message_id(outgoing),
    do:
      Map.get(outgoing.metadata || %{}, :message_id) ||
        Map.get(outgoing.metadata || %{}, "message_id")

  defp ensure_text_group([], _steps, outgoing, bridge, connection, requirements, failures) do
    body =
      if Enum.any?(failures, &(&1.stage == :selection)),
        do:
          Enum.join(
            Enum.reject(
              [outgoing.body, delivery_error(:invalid_attachment_selection).message],
              &(&1 == "")
            ),
            "\n\n"
          ),
        else: outgoing.body

    notice = %{outgoing | body: body}

    prepared = prepare_text_message(notice, bridge, connection, requirements)

    case prepared do
      {:ok, prepared} ->
        existing =
          if function_exported?(bridge, :existing_text_message, 2),
            do: bridge.existing_text_message(outgoing, connection)

        operation = if is_nil(existing), do: :send, else: :edit

        {:ok,
         [
           %{
             id: 0,
             file_refs: [],
             body: body,
             canonical_body: outgoing.body,
             notice?: Enum.any?(failures, &(&1.stage == :selection)),
             prepared: prepared
           }
         ],
         [
           %Step{
             id: {operation, 0},
             operation: operation,
             group_id: 0,
             prepared: prepared,
             message_ref: if(is_nil(existing), do: nil, else: {:existing, existing})
           }
         ]}

      {:error, reason} ->
        {:error, normalize_planning_error(reason)}
    end
  end

  defp ensure_text_group(
         groups,
         steps,
         _outgoing,
         _bridge,
         _connection,
         _requirements,
         _failures
       ),
       do: {:ok, groups, steps}

  defp prepare_text_message(outgoing, bridge, connection, %{max_encoded_message_bytes: ceiling})
       when is_integer(ceiling),
       do: prepare_encoded_message(outgoing, [], bridge, connection, ceiling)

  defp prepare_text_message(outgoing, bridge, connection, _requirements) do
    if function_exported?(bridge, :prepare_delivery_message, 3),
      do: bridge.prepare_delivery_message(outgoing, [], connection),
      else: {:ok, nil}
  end

  defp preparation_gate(:abort, [%{stage: :selection} | _]),
    do: {:error, delivery_error(:invalid_attachment_selection)}

  defp preparation_gate(:abort, [failure | _]) do
    {:error,
     %DeliveryError{
       reason: {:attachment_preparation_failed, failure.reason},
       message: failure.reason,
       stage: failure.stage,
       delivery: :not_sent
     }}
  end

  defp preparation_gate(_policy, _failures), do: :ok

  defp planning_failure(index, error),
    do: %{
      attachment_index: index,
      stage: error.stage,
      delivery: error.delivery,
      reason: error.message
    }

  defp normalize_planning_error(%DeliveryError{} = error), do: error

  defp normalize_planning_error(reason)
       when reason in [:file_too_large, :message_too_large, :upload_request_too_large],
       do: %DeliveryError{
         reason: reason,
         message: "The attachment cannot fit the connector's delivery limits.",
         stage: :preparation,
         delivery: :not_sent
       }

  defp normalize_planning_error(reason), do: delivery_error(reason)

  @doc """
  Returns prepared files in input order, or a preparation error.

  Decodes only explicitly declared standard base64 content through `DecodeBase64`,
  accepting whitespace and optional padding; nil or `"binary"` encoding
  preserves bytes verbatim. Empty attachments return `{:ok, []}` without source access.
  `:node_router` in opts is a local execution dependency, never an identity input.
  With `:attachment_failure_policy`, returns `{:ok, files, failures}` and gives
  each prepared file its original `:attachment_index`. `:continue` retains usable
  files after failures; `:abort` returns the first preparation error. Omitting the
  option preserves the two-element success tuple and fail-fast behavior.
  """
  @spec prepare([Record.t()], map(), keyword()) ::
          {:ok, [prepared()]} | {:ok, [prepared()], [map()]} | {:error, term()}
  def prepare(records, context, opts \\ [])

  def prepare(records, context, opts)
      when is_list(records) and is_map(context) and is_list(opts) do
    source_context =
      context
      |> TrustedContext.normalize()
      |> Map.from_struct()
      |> Map.merge(Map.new(Keyword.take(opts, [:node_router])))

    case Keyword.get(opts, :attachment_failure_policy) do
      policy when policy in [nil, :continue, :abort] ->
        prepare_all(records, source_context, policy)

      policy ->
        {:error, {:invalid_attachment_failure_policy, policy}}
    end
  end

  def prepare(_records, _context, _opts),
    do: {:error, :invalid_attachments}

  @doc "Maps shared attachment selection and preparation failures before transport."
  @spec delivery_error(term()) :: DeliveryError.t()
  def delivery_error(:invalid_attachment_selection) do
    %DeliveryError{
      reason: :invalid_attachment_selection,
      message: "The requested files could not be attached.",
      stage: :selection,
      delivery: :not_sent
    }
  end

  def delivery_error(reason) do
    %DeliveryError{
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

  defp prepare_all(records, context, policy) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {record, index}, accumulator ->
      prepare_next(record, index, context, policy, accumulator)
    end)
    |> case do
      {:ok, files, _failures} when is_nil(policy) -> {:ok, Enum.reverse(files)}
      {:ok, files, failures} -> {:ok, Enum.reverse(files), Enum.reverse(failures)}
      error -> error
    end
  end

  defp prepare_next(record, index, context, policy, {:ok, files, failures}) do
    case prepare_record(record, context) do
      {:ok, file} ->
        prepared = if is_nil(policy), do: file, else: Map.put(file, :attachment_index, index)
        {:cont, {:ok, [prepared | files], failures}}

      {:error, reason} when policy == :continue ->
        failure = %{
          attachment_index: index,
          stage: :preparation,
          delivery: :not_sent,
          reason: delivery_error(reason).message
        }

        {:cont, {:ok, files, [failure | failures]}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

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
