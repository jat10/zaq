defmodule Zaq.Channels.Delivery.AttemptReportingTest do
  use ExUnit.Case, async: true
  import Mox

  alias Zaq.Channels.Delivery.{Error, Plan, Result}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.DeliveryConfirmation
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  setup :verify_on_exit!

  test "confirmed parts retain canonical content and only delivered file facts; failures group once" do
    outgoing = outgoing()
    result = result()
    response = {:ok, result}

    expect(Zaq.NodeRouterMock, :dispatch, 3, fn event ->
      send(self(), {:report, event})
      %{event | response: {:ok, %{}}}
    end)

    assert ^response =
             DeliveryConfirmation.record_attempt(response, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )

    assert_receive {:report, first}
    assert first.opts[:action] == :record_delivery_confirmation
    assert first.request.outgoing.body == "canonical answer"
    assert first.request.outgoing.attachments == []

    assert first.request.receipt.attachments == [
             %{"id" => "provider-0", "name" => "first.pdf", "kind" => "file", "size" => 4}
           ]

    assert first.request.receipt.delivery_part.primary?
    assert_receive {:report, last}
    assert last.request.outgoing.body == "Additional files (3/3)."
    refute last.request.receipt.delivery_part.primary?
    assert last.request.outgoing.thread_id == "root"
    assert_receive {:report, grouped}
    assert grouped.opts[:action] == :record_delivery_observation

    assert grouped.request.assistant_message_id ==
             outgoing.metadata.persisted_assistant_message_id

    assert grouped.request.channel_config_id == 12

    assert [%{group_id: 1, outcome: :unconfirmed, reason: :timeout}] =
             grouped.request.delivery_parts.parts

    refute inspect([first.request, last.request, grouped.request]) =~ "SECRET"
    refute_received {:report, _}
  end

  test "reporting failure preserves all transport results and continues remaining reports" do
    response = {:ok, result()}
    expect(Zaq.NodeRouterMock, :dispatch, 3, fn _ -> exit(:engine_unavailable) end)

    assert ^response =
             DeliveryConfirmation.record_attempt(response, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "missing persisted answer cannot produce a grouped observation" do
    outgoing = %{
      outgoing()
      | metadata: %{user_message_id: Ecto.UUID.generate(), persisted_assistant_message_id: nil}
    }

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn event -> event end)

    assert {:ok, _} =
             DeliveryConfirmation.record_attempt({:ok, result()}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "a thrown Engine report cannot erase a confirmed attempt or stop the remaining reports" do
    response = {:ok, result()}
    expect(Zaq.NodeRouterMock, :dispatch, 3, fn _ -> throw(:engine_unavailable) end)

    assert ^response =
             DeliveryConfirmation.record_attempt(response, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "malformed private result evidence cannot cross the Engine boundary" do
    response = {:ok, %Result{attempt_id: "invalid", steps: []}}

    assert ^response =
             DeliveryConfirmation.record_attempt(response, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  defp outgoing do
    %Outgoing{
      body: "canonical answer",
      provider: :mattermost,
      channel_id: "room",
      routing_context: %{channel_config_id: 12},
      metadata: %{
        user_message_id: Ecto.UUID.generate(),
        persisted_assistant_message_id: Ecto.UUID.generate(),
        assistant_message_id: "SECRET-reserved",
        private: "SECRET"
      },
      attachments: [
        %Record{
          id: "SECRET-source-handle",
          kind: :file,
          content: "SECRET",
          name: "first.pdf",
          size: 4
        },
        %Record{id: "other", kind: :file},
        %Record{id: "last", kind: :file}
      ]
    }
  end

  defp result do
    steps =
      for group <- 0..2,
          do: %Step{
            id: {:send, group},
            operation: :send,
            group_id: group,
            attachment_refs: [group]
          }

    plan = %Plan{
      requirements: %TransportRequirements{
        transfer_mode: :send_with_attachments,
        max_attachments_per_message: 1
      },
      groups: [],
      steps: steps,
      placement: :threaded
    }

    outcomes = %{
      {:send, 0} => %{
        outcome: :confirmed,
        receipt: %{
          confirmation: :confirmed,
          message_id: "root",
          private: "SECRET",
          attachment_refs: %{0 => "provider-0"}
        },
        delivered_attachment_refs: [0],
        publication: %{body: "formatted answer", thread_id: nil, continuation?: false}
      },
      {:send, 1} => %{
        outcome: :unconfirmed,
        error: %Error{
          stage: :publication,
          outcome: :unconfirmed,
          reason: :timeout,
          cause: "SECRET"
        }
      },
      {:send, 2} => %{
        outcome: :confirmed,
        receipt: %{confirmation: :confirmed, message_id: "last", thread_id: "root"},
        delivered_attachment_refs: [2],
        publication: %{body: "Additional files (3/3).", thread_id: "root", continuation?: true}
      }
    }

    Result.new(plan, outcomes, Ecto.UUID.generate())
  end
end
