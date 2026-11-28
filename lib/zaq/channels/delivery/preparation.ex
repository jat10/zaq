defmodule Zaq.Channels.Delivery.Preparation do
  @moduledoc """
  Attempt-local attachment acquisition and request preparation for Channel delivery.

  Redeems lazy Records through `Zaq.Materialization`, retaining its signed-handle
  authorization contract. Only trusted identity, literal permission bypass and
  local router/config dependencies are supplied to redemption. Nil identity never
  creates a bypass. Materialized Records are treated as already authorized bytes.

  Acquired content is transient and separate from source Records and delivery
  plans. Successful and failed acquisitions are cached by original attachment index
  within one attempt. Fixed groups reuse the existing byte validations; bridges
  encode requests through optional pure callbacks. Prepared sizes are checked
  against resolved limits, including after changed body/thread inputs.

  This module does not regroup, upload or publish. The executor owns operation
  order, policy, deadlines and release calls. Upload bytes live through their upload
  consumers; direct-send bytes live through final message encoding/publication.
  """

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Channels.Delivery.{Attachments, Error, Plan}
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @enforce_keys [:plan, :records, :context, :pending_steps]
  @derive {Inspect, only: []}
  defstruct [
    :plan,
    :records,
    :context,
    :pending_steps,
    cache: %{},
    prepared: %{},
    failures: %{},
    closed?: false
  ]

  @type t :: %__MODULE__{
          plan: Plan.t(),
          records: map(),
          context: map(),
          pending_steps: map(),
          cache: map(),
          prepared: map(),
          failures: map(),
          closed?: boolean()
        }

  @type attachment :: %{
          content: binary(),
          size: non_neg_integer(),
          name: String.t(),
          mime_type: String.t()
        }

  @doc "Starts isolated preparation after validating metadata and resolved requirements."
  @spec start(Outgoing.t(), Plan.t(), map()) :: {:ok, t()} | {:error, term()}
  def start(outgoing, plan, context \\ %{})

  def start(%Outgoing{attachments: records}, %Plan{} = plan, context)
      when is_list(records) and is_map(context) do
    with :ok <- Plan.validate(plan, length(records)),
         :ok <- Attachments.validate_requirements(plan.requirements) do
      {:ok,
       %__MODULE__{
         plan: plan,
         records:
           records |> Enum.with_index() |> Map.new(fn {record, index} -> {index, record} end),
         context: trusted_context(context),
         pending_steps: Map.new(plan.steps, &{&1.id, &1})
       }}
    end
  end

  def start(_outgoing, _plan, _context), do: {:error, :invalid_preparation_inputs}

  @doc "Acquires a fixed group once; continue returns usable files with original indices."
  @spec acquire_group(t(), non_neg_integer()) :: {:ok, [map()], t()} | {:error, Error.t(), t()}
  def acquire_group(%__MODULE__{closed?: false} = attempt, group_id) do
    case Enum.find(attempt.plan.groups, &(&1.id == group_id)) do
      %{attachment_refs: refs} = group -> acquire_fixed_group(attempt, group, refs)
      _ -> {:error, preparation_error(:invalid_group), attempt}
    end
  end

  def acquire_group(attempt, _group_id),
    do: {:error, preparation_error(:closed_preparation), attempt}

  @doc "Re-encodes one step for its current inputs and validates the exact prepared size."
  @spec prepare_step(t(), term(), map(), module(), map()) ::
          {:ok, map(), t()} | {:error, Error.t(), t()}
  def prepare_step(%__MODULE__{closed?: false} = attempt, step_id, inputs, bridge, connection) do
    with {:ok, step} <- Map.fetch(attempt.pending_steps, step_id),
         {:ok, attachments} <- step_attachments(inputs, step, attempt.plan),
         :ok <- validate_raw_step(step, attachments, attempt.plan.requirements),
         {:ok, prepared} <- encode_step(step, inputs, attachments, bridge, connection),
         :ok <- validate_prepared(step, prepared, attempt.plan.requirements) do
      {:ok, prepared, put_in(attempt.prepared[step_id], prepared)}
    else
      failure -> preparation_failure(attempt, step_id, failure)
    end
  end

  def prepare_step(attempt, _step_id, _inputs, _bridge, _connection),
    do: {:error, preparation_error(:closed_preparation), attempt}

  @doc "Releases a prepared step and content with no remaining byte consumer."
  @spec release_step(t(), term()) :: t()
  def release_step(%__MODULE__{} = attempt, step_id) do
    pending = Map.delete(attempt.pending_steps, step_id)

    needed =
      pending
      |> Map.values()
      |> Enum.filter(&byte_consumer?(&1, attempt.plan))
      |> Enum.flat_map(& &1.attachment_refs)
      |> MapSet.new()

    cache =
      Map.new(attempt.cache, fn
        {index, {:ok, attachment}} ->
          {index, if(MapSet.member?(needed, index), do: {:ok, attachment}, else: :released)}

        cached ->
          cached
      end)

    %{
      attempt
      | pending_steps: pending,
        prepared: Map.delete(attempt.prepared, step_id),
        cache: cache
    }
  end

  @doc "Drops all transient inputs, content, requests and trusted context at attempt completion."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = attempt),
    do: %{
      attempt
      | records: %{},
        context: %{},
        pending_steps: %{},
        cache: %{},
        prepared: %{},
        closed?: true
    }

  @doc "Returns configuration/preparation failure facts in original group/index order."
  @spec failures(t()) :: [map()]
  def failures(%__MODULE__{} = attempt),
    do:
      attempt.failures
      |> Map.values()
      |> Enum.sort_by(&{&1.group_id, Enum.min(&1.attachment_refs, fn -> -1 end)})

  defp acquire_fixed_group(attempt, group, refs) do
    if Enum.any?(refs, &(Map.get(attempt.cache, &1) == :released)) do
      {:error, preparation_error(:released_attachment), attempt}
    else
      {attachments, attempt} =
        Enum.reduce(refs, {[], attempt}, &acquire_group_index(&1, &2, group.id))

      validate_fixed_group(attempt, group, Enum.reverse(attachments))
    end
  end

  defp acquire_group_index(index, {files, attempt}, group_id) do
    {result, attempt} = acquire_index(attempt, index)

    case result do
      {:ok, attachment} ->
        {[Map.put(attachment, :index, index) | files], attempt}

      {:error, reason} ->
        failure = %{
          group_id: group_id,
          attachment_refs: [index],
          error: preparation_error(reason)
        }

        {files, put_in(attempt.failures[{:file, index}], failure)}
    end
  end

  defp acquire_index(attempt, index) do
    case Map.fetch(attempt.cache, index) do
      {:ok, cached} ->
        {cached, attempt}

      :error ->
        result =
          acquire(Map.get(attempt.records, index), attempt.plan.requirements, attempt.context)

        {result,
         %{
           attempt
           | cache: Map.put(attempt.cache, index, result),
             records: Map.delete(attempt.records, index)
         }}
    end
  end

  defp validate_fixed_group(attempt, group, attachments) do
    case Attachments.validate_group(attachments, attempt.plan.requirements) do
      :ok ->
        group_policy(attempt, group, attachments)

      {:error, reason} ->
        error = preparation_error(reason)

        failure = %{
          group_id: group.id,
          attachment_refs: Enum.map(attachments, & &1.index),
          error: error
        }

        attempt = put_in(attempt.failures[{:group, group.id}], failure)
        group_policy(attempt, group, [])
    end
  end

  defp group_policy(attempt, group, attachments) do
    failure = Enum.find(failures(attempt), &(&1.group_id == group.id))

    if attempt.plan.requirements.failure_policy == :abort and failure,
      do: {:error, failure.error, attempt},
      else: {:ok, attachments, attempt}
  end

  defp step_attachments(%{attachments: files}, step, plan) when is_list(files) do
    group = Enum.find(plan.groups, &(&1.id == step.group_id))
    indices = for %{index: index} <- files, do: index

    if length(indices) == length(files) and MapSet.size(MapSet.new(indices)) == length(indices) and
         Enum.all?(indices, &(&1 in group.attachment_refs)) do
      {:ok, Enum.filter(files, &(&1.index in step.attachment_refs))}
    else
      {:error, :invalid_attachment_indices}
    end
  end

  defp step_attachments(_inputs, _step, _plan), do: {:error, :invalid_preparation_inputs}

  defp validate_raw_step(%{operation: :upload}, attachments, requirements),
    do: Attachments.validate_upload_group(attachments, requirements)

  defp validate_raw_step(
         _step,
         attachments,
         %{transfer_mode: :send_with_attachments} = requirements
       ),
       do: Attachments.validate_group(attachments, requirements)

  defp validate_raw_step(_step, _attachments, _requirements), do: :ok

  defp encode_step(%{operation: :upload}, _inputs, files, bridge, connection),
    do: safe_encode(fn -> bridge.prepare_upload_request(files, connection) end)

  defp encode_step(_step, %{outgoing: %Outgoing{} = outgoing} = inputs, files, bridge, connection) do
    connection =
      Map.put(connection, :delivery_continuation?, Map.get(inputs, :continuation?, false))

    safe_encode(fn -> bridge.prepare_delivery_message(outgoing, files, connection) end)
  end

  defp encode_step(_step, _inputs, _files, _bridge, _connection),
    do: {:error, :invalid_preparation_inputs}

  defp safe_encode(callback) do
    callback.()
  rescue
    _ -> {:error, :request_preparation_exception}
  catch
    _, _ -> {:error, :request_preparation_exit}
  end

  defp validate_prepared(%{operation: :upload}, %{size_bytes: :unresolved}, _requirements),
    do: {:error, :invalid_prepared_request}

  defp validate_prepared(step, prepared, requirements) do
    limit =
      if step.operation == :upload,
        do: requirements.max_upload_request_bytes,
        else: requirements.max_encoded_message_bytes

    validate_request(prepared, limit)
  end

  @doc "Checks exact sizes; unknown publication sizes require an unresolved or inapplicable ceiling."
  @spec validate_request(map(), TransportRequirements.limit()) :: :ok | {:error, atom()}
  def validate_request(%{size_bytes: size}, limit) when is_integer(size) and size >= 0 do
    cond do
      limit in [:unresolved, :not_applicable] -> :ok
      is_integer(limit) and limit > 0 and size <= limit -> :ok
      is_integer(limit) and limit > 0 -> {:error, :encoded_request_too_large}
      true -> {:error, :invalid_prepared_request}
    end
  end

  def validate_request(%{size_bytes: :unresolved}, limit)
      when limit in [:unresolved, :not_applicable], do: :ok

  def validate_request(_prepared, _limit), do: {:error, :invalid_prepared_request}

  defp preparation_failure(attempt, step_id, reason) do
    error = preparation_error(reason)
    step = Enum.find(attempt.plan.steps, &(&1.id == step_id))
    attempt = %{attempt | prepared: Map.delete(attempt.prepared, step_id)}

    attempt =
      if step do
        put_in(attempt.failures[{:step, step_id}], %{
          group_id: step.group_id,
          attachment_refs: step.attachment_refs,
          error: error
        })
      else
        attempt
      end

    {:error, error, attempt}
  end

  defp preparation_error({:error, reason}), do: preparation_error(reason)

  defp preparation_error(reason) do
    code =
      case reason do
        reason
        when reason in [
               :file_too_large,
               :message_too_large,
               :upload_request_too_large,
               :encoded_request_too_large
             ] ->
          :size_limit

        reason
        when reason in [
               :invalid_attachment,
               :invalid_attachment_metadata,
               :invalid_attachment_encoding,
               :invalid_attachment_base64
             ] ->
          :invalid_attachment

        :attachment_content_unavailable ->
          :content_unavailable

        _ ->
          :preparation_failed
      end

    %Error{stage: :preparation, outcome: :failed, reason: code, cause: reason}
  end

  defp byte_consumer?(step, %{requirements: %{transfer_mode: :upload_then_publish}}),
    do: step.operation == :upload

  defp byte_consumer?(step, _plan), do: step.operation in [:send, :edit]

  @doc """
  Acquires one Record and checks metadata and actual raw byte limits.

  Absent, binary and UTF-8 encoding preserve content bytes; explicitly declared
  standard base64 is decoded. Returns transient bytes with safe display defaults and actual
  size; metadata size drift is accepted when actual limits permit it. Optional
  unresolved limits remain deferred to the provider. Source Records are unchanged.
  """
  @spec acquire(Record.t(), TransportRequirements.t(), map()) ::
          {:ok, attachment()} | {:error, term()}
  def acquire(record, requirements, context \\ %{})

  def acquire(record, requirements, context) when is_map(context) do
    with :ok <- Attachments.validate_requirements(requirements),
         :ok <- Attachments.validate_metadata(record),
         {:ok, materialized} <- materialize(record, trusted_context(context)),
         :ok <- Attachments.validate_metadata(materialized),
         {:ok, content} <- decode_content(materialized),
         attachment = %{
           content: content,
           size: byte_size(content),
           name: materialized.name || record.name || "attachment",
           mime_type: materialized.mime_type || record.mime_type || "application/octet-stream"
         },
         :ok <- Attachments.validate_group([attachment], requirements) do
      {:ok, attachment}
    end
  rescue
    _ -> {:error, :attachment_preparation_exception}
  catch
    _, _ -> {:error, :attachment_preparation_exit}
  end

  def acquire(_record, _requirements, _context), do: {:error, :invalid_trusted_context}

  defp trusted_context(context) do
    context
    |> TrustedContext.normalize()
    |> Map.from_struct()
    |> Map.merge(Map.take(context, [:node_router, :config]))
  end

  defp materialize(%Record{content: content} = record, _context) when is_binary(content),
    do: {:ok, record}

  defp materialize(%Record{content: nil, materialization_handle: handle}, context)
       when is_binary(handle) and handle != "" do
    case Materialization.materialize(handle, context, "Attachment acquisition failed") do
      {:ok, %{record: record}} -> {:ok, record}
      {:error, _} = error -> error
    end
  end

  defp materialize(%Record{content: nil}, _context),
    do: {:error, :attachment_content_unavailable}

  defp materialize(_record, _context), do: {:error, :invalid_attachment_content}

  defp decode_content(%Record{content: content, attributes: attributes})
       when is_binary(content) do
    case Map.get(attributes, "encoding", Map.get(attributes, :encoding)) do
      "base64" ->
        case Jido.Exec.run(DecodeBase64, %{data: content, variant: "standard"}, %{}) do
          {:ok, %{decoded: bytes}} -> {:ok, bytes}
          {:error, _} -> {:error, :invalid_attachment_base64}
        end

      encoding when encoding in [nil, "binary", "utf-8"] ->
        {:ok, content}

      _ ->
        {:error, :invalid_attachment_encoding}
    end
  end

  defp decode_content(_record), do: {:error, :invalid_attachment_content}
end
