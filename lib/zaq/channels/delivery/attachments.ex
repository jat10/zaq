defmodule Zaq.Channels.Delivery.Attachments do
  @moduledoc """
  Pure metadata validation and ordered attachment delivery planning within Channel.

  The caller selects the outbound connection and supplies requirements from
  `TransportRequirements.resolve/2`. Resolution failures are returned unchanged;
  failure policy is left to execution. Empty attachments return no plan.

  Unknown Record sizes contribute no known lower bound, rather than a claim of
  zero bytes. Known sizes constrain packing; actual content and encoded requests
  require validation during execution. Planning never redeems handles, decodes,
  encodes or invokes a bridge. Invalid attachments reject the plan at their
  original index without dropping or reindexing other inputs.
  """

  alias Zaq.Channels.Delivery.Plan
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  @byte_limits [
    :max_attachment_bytes,
    :max_attachment_bytes_per_message,
    :max_encoded_message_bytes,
    :max_upload_request_bytes
  ]

  @doc """
  Returns a separate plan, or nil for text-only messages. A supplied existing
  message is edited only when requirements explicitly support attachment edits.
  Errors retain resolver reasons or identify an invalid attachment's original index.
  """
  @spec build_plan(Outgoing.t(), TransportRequirements.t() | {:error, term()}, String.t() | nil) ::
          {:ok, Plan.t() | nil} | {:error, term()}
  def build_plan(outgoing, requirements, existing_message_id \\ nil)

  def build_plan(%Outgoing{attachments: []}, _requirements, _existing), do: {:ok, nil}

  def build_plan(%Outgoing{attachments: records}, _requirements, _existing)
      when not is_list(records),
      do: {:error, :invalid_attachments}

  def build_plan(%Outgoing{body: body}, _requirements, _existing) when not is_binary(body),
    do: {:error, :invalid_postable}

  def build_plan(%Outgoing{}, {:error, _} = error, _existing), do: error

  def build_plan(%Outgoing{attachments: records}, requirements, existing) do
    with :ok <- validate_requirements(requirements),
         {:ok, metadata} <- metadata(records),
         {:ok, batches} <- pack(metadata, &validate_group(&1, requirements)) do
      groups =
        batches
        |> Enum.with_index()
        |> Enum.map(fn {batch, id} -> %{id: id, attachment_refs: Enum.map(batch, & &1.index)} end)

      steps = plan_steps(batches, requirements, existing)

      {:ok,
       %Plan{
         requirements: requirements,
         placement: if(requirements.supports_threads, do: :threaded, else: :independent),
         groups: groups,
         steps: steps
       }}
    end
  end

  @doc "Checks the shape of supplied requirements without deriving or resolving them."
  @spec validate_requirements(term()) :: :ok | {:error, :invalid_requirements}
  def validate_requirements(%TransportRequirements{} = requirements) do
    valid? =
      requirements.transfer_mode in [:upload_then_publish, :send_with_attachments] and
        is_integer(requirements.max_attachments_per_message) and
        requirements.max_attachments_per_message > 0 and
        requirements.failure_policy in [:continue, :abort] and
        is_boolean(requirements.supports_threads) and
        is_boolean(requirements.supports_attachment_edits) and
        Enum.all?(@byte_limits, &valid_limit?(Map.fetch!(requirements, &1)))

    if valid?, do: :ok, else: {:error, :invalid_requirements}
  end

  def validate_requirements(_), do: {:error, :invalid_requirements}

  defp valid_limit?(limit) when limit in [:unresolved, :not_applicable], do: true
  defp valid_limit?(limit), do: is_integer(limit) and limit > 0

  @doc "Validates a file Record's metadata without examining or acquiring content."
  @spec validate_metadata(term()) :: :ok | {:error, atom()}
  def validate_metadata(%Record{id: id, kind: :file, size: size, attributes: attributes} = record)
      when is_binary(id) and id != "" and is_map(attributes) and
             (is_nil(size) or (is_integer(size) and size >= 0)) do
    if valid_name?(record.name) and valid_mime?(record.mime_type),
      do: :ok,
      else: {:error, :invalid_attachment_metadata}
  end

  def validate_metadata(_), do: {:error, :invalid_attachment}

  defp metadata(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, metadata} ->
      case validate_metadata(record) do
        :ok -> {:cont, {:ok, [%{index: index, size: raw_size(record)} | metadata]}}
        {:error, reason} -> {:halt, {:error, {:invalid_attachment, index, reason}}}
      end
    end)
    |> case do
      {:ok, metadata} -> {:ok, Enum.reverse(metadata)}
      error -> error
    end
  end

  # IMAP Records retain MIME encoded_size, including after history hydration.
  # Other producers may report raw size even when their content is base64.
  defp raw_size(%Record{
         attributes: %{
           "materialization_source" => %{
             "type" => "communication_media",
             "locator" => %{"provider" => "email:imap"}
           }
         }
       }),
       do: nil

  defp raw_size(%Record{size: size}), do: size

  @doc """
  Checks count and known raw byte lower bounds for a fixed message group.

  Accepts size maps from metadata planning or acquired content. Unknown metadata
  sizes cannot establish a fit. Exact encoded request sizing remains the executor's
  responsibility, including for positive encoded-message limits. Raw attachment
  bytes bound encoded messages only for direct sends; upload publication carries
  references whose encoded size is not determined by the file bytes.
  """
  @spec validate_group([%{required(:size) => non_neg_integer() | nil}], TransportRequirements.t()) ::
          :ok | {:error, atom()}
  def validate_group(attachments, %TransportRequirements{} = requirements) do
    known_bytes = known_bytes(attachments)

    cond do
      length(attachments) > requirements.max_attachments_per_message ->
        {:error, :message_too_large}

      Enum.any?(attachments, &exceeds?(&1.size, requirements.max_attachment_bytes)) ->
        {:error, :file_too_large}

      requirements.transfer_mode == :upload_then_publish and
          Enum.any?(attachments, &exceeds?(&1.size, requirements.max_upload_request_bytes)) ->
        {:error, :upload_request_too_large}

      exceeds?(known_bytes, requirements.max_attachment_bytes_per_message) or
          (requirements.transfer_mode == :send_with_attachments and
             exceeds?(known_bytes, requirements.max_encoded_message_bytes)) ->
        {:error, :message_too_large}

      true ->
        :ok
    end
  end

  @doc "Checks a fixed upload batch's known raw byte lower bound; request encoding remains separate."
  @spec validate_upload_group(
          [%{required(:size) => non_neg_integer() | nil}],
          TransportRequirements.t()
        ) ::
          :ok | {:error, :upload_request_too_large}
  def validate_upload_group(attachments, %TransportRequirements{} = requirements) do
    if exceeds?(known_bytes(attachments), requirements.max_upload_request_bytes),
      do: {:error, :upload_request_too_large},
      else: :ok
  end

  defp known_bytes(attachments),
    do: attachments |> Enum.map(& &1.size) |> Enum.reject(&is_nil/1) |> Enum.sum()

  defp exceeds?(size, limit) when is_integer(size) and is_integer(limit), do: size > limit
  defp exceeds?(_size, _limit), do: false

  defp pack(attachments, validate) do
    attachments
    |> Enum.reduce_while({:ok, [], []}, fn attachment, {:ok, batches, current} ->
      case validate.(Enum.reverse([attachment | current])) do
        :ok ->
          {:cont, {:ok, batches, [attachment | current]}}

        {:error, _} ->
          start_batch(attachment, validate, batches, current)
      end
    end)
    |> case do
      {:ok, batches, current} -> {:ok, Enum.reverse([Enum.reverse(current) | batches])}
      error -> error
    end
  end

  defp start_batch(attachment, validate, batches, current) do
    case validate.([attachment]) do
      :ok ->
        {:cont, {:ok, [Enum.reverse(current) | batches], [attachment]}}

      {:error, reason} ->
        {:halt, {:error, {:attachment_limit_exceeded, attachment.index, reason}}}
    end
  end

  defp plan_steps(batches, requirements, existing) do
    batches
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, id} ->
      uploads = upload_steps(batch, id, requirements)

      edit? =
        id == 0 and requirements.supports_attachment_edits and is_binary(existing) and
          existing != ""

      operation = if edit?, do: :edit, else: :send

      uploads ++
        [
          %Step{
            id: {operation, id},
            operation: operation,
            group_id: id,
            attachment_refs: Enum.map(batch, & &1.index),
            depends_on: Enum.map(uploads, & &1.id),
            message_ref: if(edit?, do: {:existing, existing})
          }
        ]
    end)
  end

  defp upload_steps(attachments, group_id, %{transfer_mode: :upload_then_publish} = requirements) do
    {:ok, batches} = pack(attachments, &validate_upload_group(&1, requirements))

    batches
    |> Enum.with_index()
    |> Enum.map(fn {batch, id} ->
      %Step{
        id: {:upload, group_id, id},
        operation: :upload,
        group_id: group_id,
        attachment_refs: Enum.map(batch, & &1.index)
      }
    end)
  end

  defp upload_steps(_attachments, _group_id, _requirements), do: []

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name) and name != "" do
    String.valid?(name) and name not in [".", ".."] and
      not String.match?(name, ~r/[\x00-\x1f\x7f\/\\]/u)
  end

  defp valid_name?(_), do: false

  defp valid_mime?(nil), do: true

  defp valid_mime?(mime_type) when is_binary(mime_type),
    do: String.match?(mime_type, ~r/\A[A-Za-z0-9!#$&^_.+\-]+\/[A-Za-z0-9!#$&^_.+\-]+\z/)

  defp valid_mime?(_), do: false
end
