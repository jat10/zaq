defmodule Zaq.Channels.DeliveryContractTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.{Api, EmailBridge, JidoChatBridge, TransportRequirements, WebBridge}
  alias Zaq.Channels.Web.{Delivery, Response}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Event

  test "the existing Channel entrypoint retains text delivery without acquiring supplied files" do
    topic = "chat:pr4-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    incoming = %Incoming{
      content: "question",
      provider: :web,
      channel_id: "session",
      routing_context: %RoutingContext{
        attributes: %{"web_delivery" => topic |> Delivery.bo() |> Delivery.reference()}
      }
    }

    records = [%Record{id: "lazy", kind: :file, materialization_handle: "cannot-be-redeemed"}]

    outgoing =
      Outgoing.from_pipeline_result(incoming, %{
        answer: "answer",
        request_id: "request",
        attachments: records
      })

    event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

    assert %{response: {:ok, %{delivered: true}}} =
             Api.handle_event(event, :deliver_outgoing, nil)

    assert_receive {:web_response, :pipeline_result,
                    %Response{type: :message_complete, payload: payload}}

    assert payload.body == "answer"
    refute Map.has_key?(payload, :attachments)
    refute Map.has_key?(payload, :plan)
    assert outgoing.attachments == records
  end

  test "selected Jido adapters declare support without inventing file requirements" do
    for provider <- [:mattermost, :telegram, :discord] do
      connection = %{id: 42, provider: provider, settings: %{}}
      assert {:ok, snapshot} = JidoChatBridge.capability_snapshot(connection)
      assert snapshot.resolved.file in [:native, :fallback]
      refute Map.has_key?(snapshot, :file_delivery)

      assert {:error, :capabilities_unavailable} =
               TransportRequirements.resolve(snapshot, connection)
    end
  end

  test "SMTP settings and generic web editing do not advertise attachment delivery" do
    for {bridge, provider} <- [
          {EmailBridge, "email:smtp"},
          {EmailBridge, "email:imap"},
          {WebBridge, :web},
          {WebBridge, :web_widget}
        ] do
      connection = %{id: 42, provider: provider, settings: %{}}
      assert {:ok, snapshot} = bridge.capability_snapshot(connection)
      assert {:error, :unsupported} = TransportRequirements.resolve(snapshot, connection)
    end
  end
end
