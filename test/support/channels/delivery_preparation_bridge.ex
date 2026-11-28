defmodule Zaq.Test.DeliveryPreparationBridge do
  @moduledoc false
  @behaviour Zaq.Channels.CommunicationBridge

  @impl true
  def prepare_upload_request(attachments, connection) do
    send(connection.owner, {:prepared_upload, Enum.map(attachments, & &1.index)})
    encode("", attachments, connection)
  end

  @impl true
  def prepare_delivery_message(outgoing, attachments, connection) do
    send(
      connection.owner,
      {:prepared_message, outgoing.body, outgoing.thread_id, Enum.map(attachments, & &1.index)}
    )

    encode([outgoing.thread_id || "", outgoing.body], attachments, connection)
  end

  @impl true
  def send_reply(_outgoing, connection) do
    send(connection.owner, :unexpected_publication)
    {:error, :unexpected_publication}
  end

  defp encode(body, attachments, connection) do
    if Map.get(connection, :invalid_payload?, false) do
      {:ok, %{body: "private", size_bytes: -1}}
    else
      content = Enum.map(attachments, &Map.get(&1, :content, ""))

      encoded =
        IO.iodata_to_binary([
          String.duplicate("h", Map.get(connection, :overhead, 0)),
          body,
          content
        ])

      {:ok, %{body: encoded, size_bytes: byte_size(encoded)}}
    end
  end
end
