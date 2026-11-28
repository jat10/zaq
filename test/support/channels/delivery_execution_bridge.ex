defmodule Zaq.Test.DeliveryExecutionBridge do
  @moduledoc false
  @behaviour Zaq.Channels.CommunicationBridge

  alias Zaq.Channels.Delivery.Error
  alias Zaq.Test.DeliveryPreparationBridge

  @impl true
  defdelegate prepare_upload_request(files, connection), to: DeliveryPreparationBridge
  @impl true
  defdelegate prepare_delivery_message(outgoing, files, connection), to: DeliveryPreparationBridge
  @impl true
  defdelegate send_reply(outgoing, connection), to: DeliveryPreparationBridge

  @impl true
  def execute_delivery_step(step, inputs, connection) do
    send(connection.owner, {:operation, step.id, self(), inputs})

    case Map.get(Map.get(connection, :responses, %{}), step.id, :confirmed) do
      :wait ->
        receive do
          {:resolve, result} -> result
        end

      :crash ->
        Process.exit(self(), :kill)

      :rejected ->
        {:error, %Error{stage: stage(step), outcome: :failed, reason: :rejected}}

      :unknown ->
        {:error, %Error{stage: stage(step), outcome: :unconfirmed, reason: :unknown}}

      :confirmed ->
        confirmation(step, inputs)

      result ->
        result
    end
  end

  defp confirmation(%{operation: :upload}, inputs),
    do: {:ok, %{uploaded_refs: Map.new(inputs.attachments, &{&1.index, "file-#{&1.index}"})}}

  defp confirmation(step, inputs),
    do:
      {:ok,
       %{
         confirmation: :confirmed,
         message_id: "message-#{step.group_id}",
         thread_id: inputs.outgoing.thread_id
       }}

  defp stage(%{operation: :upload}), do: :upload
  defp stage(_), do: :publication
end
