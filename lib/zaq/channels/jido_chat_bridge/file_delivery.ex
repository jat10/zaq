defmodule Zaq.Channels.JidoChatBridge.FileDelivery do
  @moduledoc """
  Translates explicit Jido adapter file contracts into selected-connection facts.

  Preparation and upload operations own no batching, failure policy or retries.
  Missing adapter primitives never establish production attachment readiness.
  """

  alias Jido.Chat.{Adapter, FileUpload}
  alias Zaq.Channels.Delivery.Error
  alias Zaq.Channels.JidoChatBridge.AdapterOptions
  alias Zaq.Channels.JidoChatBridge.DeliveryResult

  @doc "Adds declared limits only when the corresponding adapter operations exist."
  def snapshot(snapshot, adapter, connection) do
    capabilities = Adapter.capabilities(adapter)

    if capabilities[:uploaded_files] == :native and
         function_exported?(adapter, :file_requirements, 1) and
         function_exported?(adapter, :prepare_upload, 3) and
         function_exported?(adapter, :upload_prepared, 2) do
      declared_snapshot(snapshot, adapter, connection, capabilities)
    else
      snapshot
    end
  end

  defp declared_snapshot(snapshot, adapter, connection, capabilities) do
    case adapter.file_requirements(AdapterOptions.build(connection.provider, connection)) do
      {:ok, limits} when is_map(limits) ->
        Map.put(snapshot, :file_delivery, %{
          transfer_mode: :upload_then_publish,
          supports_attachment_edits:
            capabilities[:edit_attachments] == :native and
              function_exported?(adapter, :edit_message, 4),
          limits: %{
            max_attachments_per_message:
              limit(Map.get(limits, :max_files_per_post, :unresolved), true, true),
            max_attachment_bytes:
              limit(Map.get(limits, :max_file_size, :unresolved), true, false),
            max_upload_request_bytes:
              limit(Map.get(limits, :max_upload_request_size, :unresolved), true, false),
            max_attachment_bytes_per_message:
              limit(Map.get(limits, :max_attachment_bytes_per_message, :unresolved), true, false),
            max_encoded_message_bytes:
              limit(Map.get(limits, :max_encoded_message_bytes, :unresolved), true, false)
          }
        })

      _ ->
        snapshot
    end
  end

  defp limit(value, configurable, required),
    do: %{
      value: value,
      configurable: configurable and value != :not_applicable,
      required: required
    }

  @doc "Prepares exactly one materialized upload candidate at the adapter boundary."
  def prepare_upload(files, adapter, connection) do
    uploads =
      Enum.map(files, fn file ->
        FileUpload.new(%{
          data: file.content,
          filename: file.name,
          media_type: file.mime_type,
          size_bytes: file.size
        })
      end)

    with {:ok, request} <-
           adapter.prepare_upload(
             connection.delivery_channel_id,
             uploads,
             AdapterOptions.build(connection.provider, connection)
           ) do
      {:ok, %{size_bytes: request.size_bytes, request: request}}
    end
  end

  @doc "Uploads a prepared request once and maps only confirmed identities to original indices."
  def upload(inputs, adapter, connection) do
    opts =
      AdapterOptions.build(inputs.outgoing.provider, connection)
      |> Keyword.put(:partial_upload_facts, true)
      |> Keyword.put(:thread_id, inputs.outgoing.thread_id)

    case adapter.upload_prepared(inputs.prepared.request, opts) do
      {:ok, %{files: files}} when is_list(files) ->
        complete_upload(files, inputs, adapter)

      {:error, {:partial_upload, %{files: files}}} = response when is_list(files) ->
        refs = indexed_references(files, inputs.attachments)
        {:error, error(adapter, response, :upload), %{uploaded_refs: refs}}

      response ->
        {:error, error(adapter, response, :upload)}
    end
  end

  defp complete_upload(files, inputs, adapter) do
    ids = Enum.map(files, &Map.get(&1, :id))

    if length(files) == length(inputs.attachments) and
         Enum.all?(ids, &valid_id?/1) and length(Enum.uniq(ids)) == length(ids) do
      {:ok,
       %{uploaded_refs: Enum.zip_with(inputs.attachments, ids, &{&1.index, &2}) |> Map.new()}}
    else
      {:error, error(adapter, {:error, :unconfirmed_upload}, :upload)}
    end
  end

  defp indexed_references(files, attachments) do
    indices = Enum.map(files, &Map.get(&1, :input_index))
    ids = Enum.map(files, &Map.get(&1, :id))

    if Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < length(attachments))) and
         Enum.all?(ids, &valid_id?/1) and length(Enum.uniq(indices)) == length(indices) and
         length(Enum.uniq(ids)) == length(ids) do
      Map.new(files, &{Enum.at(attachments, &1.input_index).index, &1.id})
    else
      %{}
    end
  end

  defp valid_id?(id), do: is_binary(id) and byte_size(id) > 0

  @doc "Classifies provider errors conservatively without exposing their private causes."
  def error(adapter, response, stage) do
    facts =
      DeliveryResult.delivery_observation(adapter, response) ||
        %{outcome: :unconfirmed, reason: :unknown}

    struct!(Error, Map.merge(facts, %{stage: stage, cause: response}))
  end
end
