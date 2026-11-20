defmodule Zaq.TestSupport.GroupDeliveryBridge do
  @moduledoc false

  alias Zaq.Channels.Delivery.Error

  def prepare_upload_request(attachments, connection) do
    indices = Enum.map(attachments, & &1.attachment_index)
    send(connection.test_pid, {:delivery_event, :prepare_upload, indices})

    if fails?(connection, :upload_preparation, indices),
      do: {:error, :invalid_prepared_message},
      else: {:ok, %{encoded_bytes: Enum.sum(Enum.map(attachments, & &1.size))}}
  end

  def prepare_delivery_message(_outgoing, attachments, connection) do
    indices = Enum.map(attachments, & &1.attachment_index)
    send(connection.test_pid, {:delivery_event, :prepare_message, indices})

    if fails?(connection, :message_preparation, indices),
      do: {:error, :invalid_prepared_message},
      else: {:ok, %{encoded_bytes: 0}}
  end

  def execute_delivery_step(step, inputs, connection) do
    indices = Enum.map(inputs.attachments, & &1.attachment_index)
    send(connection.test_pid, {:delivery_event, step.operation, indices})
    send(connection.test_pid, {:delivery_inputs, step, inputs})

    if step.operation == :upload do
      uploaded = Enum.map(indices, &%{id: "file-#{&1}", attachment_index: &1})

      if fails?(connection, :upload, indices) do
        {:error,
         %Error{
           reason: :upload_failed,
           message: "The upload failed.",
           stage: :upload,
           delivery: :not_sent
         }, %{uploaded_attachments: Enum.take(uploaded, Map.get(connection, :partial_count, 0))}}
      else
        {:ok, %{uploaded_attachments: uploaded}}
      end
    else
      {:ok, %{confirmation: :confirmed, message_id: "message-#{step.group_id}", action: :created}}
    end
  end

  def delivery_completed(outgoing, report, connection),
    do: send(connection.test_pid, {:delivery_completed, outgoing, report})

  defp fails?(connection, stage, indices),
    do: connection[:failure_stage] == stage and connection[:failure_index] in indices
end
