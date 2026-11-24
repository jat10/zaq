defmodule Zaq.Channels.Delivery.ConfirmationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Channels.Delivery.Confirmation
  alias Zaq.Channels.Delivery.Plan
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.EventHop

  setup :verify_on_exit!

  test "an unnumbered partial root records the canonical answer while retaining actual formatted receipt text" do
    outgoing = %{outgoing() | body: "Original answer"}
    receipt = %{confirmation: :confirmed, message_id: "root", body: "<p>Original answer</p>"}

    report = %{
      confirmation: :partial,
      messages: [receipt],
      failed_attachments: [%{attachment_index: 0}]
    }

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn event ->
      assert event.request.outgoing.body == "Original answer"
      assert event.request.receipt.body == "<p>Original answer</p>"
      %{event | response: {:ok, event.request.receipt}}
    end)

    assert {:ok, recorded} =
             Confirmation.record({:ok, report}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )

    assert {:ok, ^recorded} =
             Confirmation.record({:ok, recorded}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "single and multiple message reports retain canonical bodies, threads and delivered attachments" do
    attachments =
      for index <- 0..5 do
        %Record{
          id: "source-#{index}",
          kind: :file,
          name: "file-#{index}.txt",
          content: "private bytes",
          materialization_handle: "handle-#{index}"
        }
      end

    outgoing = %{
      outgoing()
      | body: "Original **answer**",
        thread_id: "existing-root",
        delivery: %Outgoing.Delivery{attachments: attachments}
    }

    for count <- [1, 3] do
      messages =
        for index <- 0..(count - 1) do
          receipt = %{
            confirmation: :confirmed,
            message_id: "provider-#{index}",
            thread_id: "existing-root",
            body:
              if(index == 0, do: "<p>Original <strong>answer</strong></p>", else: "More files"),
            delivered_attachment_indices: [index * 2]
          }

          if index == 0, do: receipt, else: Map.put(receipt, :delivery_part_index, index)
        end

      for {receipt, index} <- Enum.with_index(messages) do
        expect(Zaq.NodeRouterMock, :dispatch, fn event ->
          assert event.opts == [action: :record_delivery_confirmation]
          assert event.request.receipt.message_id == "provider-#{index}"
          assert event.request.receipt.body == receipt.body
          assert event.request.receipt.thread_id == "existing-root"
          refute Map.has_key?(event.request.receipt, :delivered_attachment_indices)
          assert event.request.outgoing.thread_id == "existing-root"

          assert event.request.outgoing.metadata == %{
                   user_message_id: "u-1",
                   assistant_message_id: "a-1"
                 }

          assert event.request.outgoing.body ==
                   if(index == 0, do: "Original **answer**", else: "More files")

          assert [%Record{id: id, content: nil, materialization_handle: handle}] =
                   event.request.outgoing.delivery.attachments

          assert id == "source-#{index * 2}"
          assert handle == "handle-#{index * 2}"

          assert event.request.receipt.attachments == [
                   %{"kind" => "file", "name" => "file-#{index * 2}.txt"}
                 ]

          %{event | response: {:ok, Map.put(event.request.receipt, :history_capture, :stored)}}
        end)
      end

      report = %{
        confirmation: :confirmed,
        messages: messages,
        uploaded_attachments: [],
        uploaded_only: [],
        failed_attachments: [],
        unattempted_steps: [],
        step_outcomes: []
      }

      assert {:ok, recorded} =
               Confirmation.record({:ok, report}, outgoing,
                 delivery_node_router: Zaq.NodeRouterMock
               )

      assert Map.delete(recorded, :messages) == Map.delete(report, :messages)
      assert Enum.map(recorded.messages, & &1.message_id) == Enum.map(messages, & &1.message_id)
      assert Enum.all?(recorded.messages, &(&1.history_capture == :stored))
    end

    assert Enum.all?(outgoing.delivery.attachments, &(&1.content == "private bytes"))
  end

  property "private plans never cross the Engine confirmation boundary" do
    check all(bytes <- binary(max_length: 1024)) do
      private = "PRIVATE_PREPARED_" <> Base.encode64(bytes)

      outgoing = %{
        outgoing()
        | delivery: %{
            outgoing().delivery
            | plan: %Plan{
                placement: :threaded,
                steps: [
                  %Zaq.Channels.Delivery.Plan.Step{
                    id: private,
                    operation: :send,
                    group_id: 0
                  }
                ]
              }
          }
      }

      receipt = %{confirmation: :confirmed, action: :created, message_id: "confirmed-plan"}

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.request.outgoing.delivery.plan == nil
        refute inspect(event.request) =~ private
        %{event | response: {:ok, receipt}}
      end)

      assert {:ok, ^receipt} =
               Confirmation.record({:ok, receipt}, outgoing,
                 delivery_node_router: Zaq.NodeRouterMock
               )

      assert hd(outgoing.delivery.plan.steps).id == private
    end
  end

  property "confirmation clears content while retaining attachment Records, handles, receipt and IDs" do
    check all(bytes <- binary(max_length: 2_048)) do
      receipt = %{
        confirmation: :confirmed,
        action: :created,
        message_id: "final-post",
        thread_id: "root"
      }

      ids = %{
        user_message_id: "u-1",
        assistant_message_id: "a-1",
        persisted_assistant_message_id: "stored-1"
      }

      attachments = [
        %Record{
          id: "file",
          kind: :file,
          content: bytes,
          name: "private.bin",
          materialization_handle: "materialized-file-handle",
          path: "/private/original",
          raw: %{token: "private"}
        },
        %Record{
          id: "lazy",
          kind: :file,
          materialization_handle: "private-handle",
          path: "/private/lazy"
        }
      ]

      outgoing = %{
        outgoing()
        | metadata:
            Map.merge(ids, %{
              "attachments" => attachments,
              attachments: attachments,
              trace: "private"
            }),
          delivery: %{outgoing().delivery | attachments: attachments}
      }

      [materialized, lazy] = attachments

      expected = %{
        outgoing
        | metadata: ids,
          delivery: %{outgoing.delivery | attachments: [%{materialized | content: nil}, lazy]}
      }

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:projected_confirmation, event})
        %{event | response: {:ok, receipt}}
      end)

      assert {:ok, ^receipt} =
               Confirmation.record({:ok, receipt}, outgoing,
                 delivery_node_router: Zaq.NodeRouterMock
               )

      assert_received {:projected_confirmation, event}
      assert event.request == %{receipt: receipt, outgoing: expected}
      assert event.next_hop.destination == :engine
      assert event.opts == [action: :record_delivery_confirmation]
      assert outgoing.delivery.attachments == attachments
    end
  end

  test "each confirmed message is recorded separately even when overall delivery is partial" do
    parts =
      for index <- 0..1,
          do: %{
            confirmation: :confirmed,
            message_id: "post-#{index}",
            body: "part #{index}",
            delivery_part_index: index,
            thread_id: "root"
          }

    report = %{
      confirmation: :partial,
      messages: parts,
      failed_attachments: [%{filename: "failed.txt"}]
    }

    for part <- parts do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.request.receipt == part
        assert event.request.outgoing.body == part.body
        assert event.request.outgoing.delivery.attachments == []
        %{event | response: {:ok, part}}
      end)
    end

    assert {:ok, ^report} =
             Confirmation.record({:ok, report}, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "SMTP selection filters transient source Records without inventing provider attachment evidence" do
    attachments = [
      %Record{id: "failed", kind: :file, content: "failed"},
      %Record{
        id: "sent",
        kind: :file,
        content: "sent",
        materialization_handle: "original-handle",
        path: "/private/source",
        raw: %{token: "private credential"},
        attributes: %{"materialization_source" => %{"file_id" => "private source locator"}}
      }
    ]

    outgoing = %{outgoing() | delivery: %{outgoing().delivery | attachments: attachments}}

    for partial? <- [false, true] do
      receipt = %{
        confirmation: :confirmed,
        message_id: "smtp-id",
        body: "answer",
        delivered_attachment_indices: [1, 1, -1, 50]
      }

      report = if partial?, do: %{confirmation: :partial, messages: [receipt]}, else: receipt

      request = capture_confirmation(report, outgoing)

      assert outgoing.delivery.attachments == attachments

      assert [%Record{id: "sent", content: nil, materialization_handle: "original-handle"}] =
               request.outgoing.delivery.attachments

      refute Map.has_key?(request.receipt, :delivered_attachment_indices)
      assert request.receipt.attachments == [%{"kind" => "file"}]
      refute inspect(request.receipt.attachments) =~ "private"
    end
  end

  property "explicit attachment indices persist only selected metadata in original order" do
    check all(
            count <- integer(1..8),
            indices <-
              list_of(one_of([integer(-5..12), constant(nil), constant("0"), constant(0.0)]),
                max_length: 20
              ),
            partial? <- boolean()
          ) do
      outgoing = %{
        outgoing()
        | delivery: %{
            outgoing().delivery
            | attachments:
                for index <- 0..(count - 1) do
                  %Record{
                    id: to_string(index),
                    name: "file-#{index}",
                    kind: :file,
                    content: "private bytes",
                    materialization_handle: "private handle",
                    path: "/private/path",
                    raw: %{token: "private credential"},
                    attributes: %{"materialization_source" => %{"file_id" => "private locator"}}
                  }
                end
          }
      }

      selected =
        indices
        |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 < count))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&%{"name" => "file-#{&1}", "kind" => "file"})

      receipt = %{
        confirmation: :confirmed,
        message_id: "smtp-id",
        delivered_attachment_indices: indices
      }

      report = if partial?, do: %{confirmation: :partial, messages: [receipt]}, else: receipt

      request = capture_confirmation(report, outgoing)

      assert request.receipt.attachments == selected

      assert Enum.map(request.outgoing.delivery.attachments, & &1.id) ==
               Enum.map(selected, &String.replace_prefix(&1["name"], "file-", ""))

      refute Map.has_key?(request.receipt, :delivered_attachment_indices)
      refute Jason.encode!(request.receipt.attachments) =~ "private"
    end
  end

  test "explicit provider attachment evidence takes precedence over selected source metadata" do
    outgoing = %{
      outgoing()
      | delivery: %{outgoing().delivery | attachments: [%Record{id: "source-file", kind: :file}]}
    }

    provider_metadata = %{
      "id" => "delivered-file",
      "attributes" => %{"materialization_source" => %{"file_id" => "delivered-provider-file"}}
    }

    for evidence <- [[], [provider_metadata]] do
      receipt = %{
        confirmation: :confirmed,
        message_id: "provider-id",
        delivered_attachment_indices: [0],
        attachments: evidence
      }

      request = capture_confirmation(receipt, outgoing)

      assert request.receipt.attachments == evidence
    end
  end

  test "an unsplit partial receipt preserves the original assistant identity and canonical body" do
    outgoing = %{
      outgoing()
      | body: "Original **answer**",
        metadata: %{
          assistant_message_id: "assistant-id",
          persisted_assistant_message_id: "assistant-id"
        }
    }

    receipt = %{
      confirmation: :confirmed,
      message_id: "smtp-id",
      thread_id: "root",
      delivered_attachment_indices: []
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.request.outgoing.body == "Original **answer**"
      assert event.request.outgoing.metadata == outgoing.metadata
      assert event.request.outgoing.delivery.attachments == []
      refute Map.has_key?(event.request.receipt, :body)
      %{event | response: {:ok, Map.put(event.request.receipt, :history_capture, :stored)}}
    end)

    assert {:ok, %{messages: [%{history_capture: :stored}]}} =
             Confirmation.record(
               {:ok, %{confirmation: :partial, messages: [receipt]}},
               outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "malformed SMTP selection cannot confirm additional source Records" do
    outgoing = %{
      outgoing()
      | delivery: %{
          outgoing().delivery
          | attachments: [%Record{id: "failed", kind: :file, content: "private"}]
        }
    }

    receipt = %{
      confirmation: :confirmed,
      message_id: "smtp-id",
      delivered_attachment_indices: :invalid
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.request.outgoing.delivery.attachments == []
      assert event.request.receipt.attachments == []
      %{event | response: {:ok, event.request.receipt}}
    end)

    assert {:ok, _} =
             Confirmation.record({:ok, receipt}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "unconfirmed transport outcomes pass through without dispatching a recording event" do
    for response <- [
          {:error, :preparation_failed},
          {:error, :timeout},
          {:error, %Req.TransportError{reason: :timeout}},
          {:ok, %{message_id: "unconfirmed"}}
        ] do
      assert Confirmation.record(response, outgoing(), delivery_node_router: Zaq.NodeRouterMock) ==
               response
    end
  end

  test "rescues a dispatch exception while preserving a confirmed receipt" do
    assert_recording_failure(fn -> raise "engine unavailable" end)
  end

  test "catches a dispatch exit while preserving a confirmed receipt" do
    assert_recording_failure(fn -> exit(:engine_unavailable) end)
  end

  test "reports an ambiguous timeout with only persisted identifiers and safe reason codes" do
    outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(self(), {:delivery_observation, event})
      %{event | response: {:ok, :recorded}}
    end)

    assert {:error, :timeout} =
             Confirmation.record(
               {:error, :timeout},
               outgoing,
               %{outcome: :unconfirmed, reason: :timeout},
               delivery_node_router: Zaq.NodeRouterMock
             )

    assert_received {:delivery_observation, event}
    assert event.opts[:action] == :record_delivery_observation
    assert event.opts[:confidential]

    assert event.request == %{
             user_message_id: "u-1",
             assistant_message_id: "a-1",
             channel_config_id: 12,
             outcome: :unconfirmed,
             reason: :timeout
           }
  end

  test "reports a bridge-normalized rejection without exposing the original response body" do
    outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}
    result = {:error, {403, %{"message" => "private provider detail"}}}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(self(), {:delivery_observation, event})
      event
    end)

    facts = %{outcome: :failed, reason: :rejected, provider_code: 403}

    assert Confirmation.record(result, outgoing, facts, delivery_node_router: Zaq.NodeRouterMock) ==
             result

    assert_received {:delivery_observation, event}
    assert event.request.outcome == :failed
    assert event.request.reason == :rejected
    assert event.request.provider_code == 403
    refute inspect(event.request) =~ "private provider detail"
  end

  for reason <- [:channel_disabled, :channel_archived, :channel_config_not_found] do
    test "pre-send #{reason} is a definite configuration failure" do
      outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}
      response = {:error, unquote(reason)}

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:configuration_observation, event})
        %{event | response: {:ok, :recorded}}
      end)

      assert Confirmation.record(
               response,
               outgoing,
               %{outcome: :failed, reason: :missing_configuration},
               delivery_node_router: Zaq.NodeRouterMock
             ) == response

      assert_received {:configuration_observation, event}
      assert event.opts[:action] == :record_delivery_observation
      assert event.opts[:confidential]

      assert event.request == %{
               user_message_id: "u-1",
               assistant_message_id: "a-1",
               channel_config_id: 12,
               outcome: :failed,
               reason: :missing_configuration
             }
    end
  end

  test "raw provider failures without normalized evidence remain unconfirmed for every provider" do
    response = {:error, {403, "PRIVATE_PROVIDER_BODY"}}

    for provider <- [:mattermost, "mattermost", :telegram, :unknown] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:delivery_observation, event.request})
        event
      end)

      assert Confirmation.record(response, %{outgoing() | provider: provider},
               delivery_node_router: Zaq.NodeRouterMock
             ) == response

      assert_received {:delivery_observation, observation}
      assert observation.outcome == :unconfirmed
      assert observation.reason == :unknown
      refute Map.has_key?(observation, :provider_code)
      refute inspect(observation) =~ "PRIVATE_PROVIDER_BODY"
    end
  end

  test "normalized evidence cannot forward extra fields or replace persisted message scope" do
    outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}
    response = {:error, {:opaque, "PRIVATE_PROVIDER_BODY"}}

    facts = %{
      outcome: :failed,
      reason: :rejected,
      provider_code: 403,
      assistant_message_id: "forged",
      channel_config_id: 99,
      provider_body: "PRIVATE_PROVIDER_BODY"
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(self(), {:delivery_observation, event.request})
      event
    end)

    assert Confirmation.record(response, outgoing, facts,
             delivery_node_router: Zaq.NodeRouterMock
           ) == response

    assert_received {:delivery_observation, observation}

    assert observation == %{
             user_message_id: "u-1",
             assistant_message_id: "a-1",
             channel_config_id: 12,
             outcome: :failed,
             reason: :rejected,
             provider_code: 403
           }
  end

  test "invalid normalized reason or provider codes never cross the reporting boundary" do
    for facts <- [
          %{outcome: :failed, reason: "PRIVATE_PROVIDER_BODY"},
          %{outcome: :failed, reason: :timeout},
          %{outcome: :failed, reason: :rejected, provider_code: "PRIVATE_PROVIDER_BODY"},
          %{outcome: :failed, reason: :rejected, provider_code: 1000}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:delivery_observation, event.request})
        event
      end)

      assert {:error, :opaque} =
               Confirmation.record({:error, :opaque}, outgoing(), facts,
                 delivery_node_router: Zaq.NodeRouterMock
               )

      assert_received {:delivery_observation, observation}
      assert observation.outcome in [:failed, :unconfirmed]

      if facts.reason in ["PRIVATE_PROVIDER_BODY", :timeout] do
        assert observation.outcome == :unconfirmed
        assert observation.reason == :unknown
      else
        assert observation.outcome == :failed
        assert observation.reason == :rejected
      end

      refute inspect(observation) =~ "PRIVATE_PROVIDER_BODY"
      refute Map.has_key?(observation, :provider_code)
    end
  end

  test "unsuccessful reporting preserves errors and never creates evidence for a reserved-only UUID" do
    expect(Zaq.NodeRouterMock, :dispatch, fn _ -> exit(:engine_unavailable) end)

    assert {:error, :timeout} =
             Confirmation.record({:error, :timeout}, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )

    outgoing = %{
      outgoing()
      | metadata: %{assistant_message_id: "reserved", persisted_assistant_message_id: nil}
    }

    assert {:error, :timeout} =
             Confirmation.record({:error, :timeout}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  defp capture_confirmation(report, outgoing) do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(self(), {:confirmed_request, event.request})
      %{event | response: {:ok, event.request.receipt}}
    end)

    assert {:ok, _} =
             Confirmation.record({:ok, report}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )

    assert_received {:confirmed_request, request}
    request
  end

  defp assert_recording_failure(fail) do
    receipt = %{confirmation: :confirmed, message_id: "external-1"}
    outgoing = outgoing()
    owner = self()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:dispatch_event, event})
      fail.()
    end)

    assert Confirmation.record({:ok, receipt}, outgoing, delivery_node_router: Zaq.NodeRouterMock) ==
             {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}

    assert receipt == %{confirmation: :confirmed, message_id: "external-1"}

    assert_received {:dispatch_event,
                     %Event{
                       request: %{receipt: ^receipt, outgoing: routed},
                       next_hop: %EventHop{destination: :engine},
                       opts: [action: :record_delivery_confirmation]
                     }}

    assert routed.body == outgoing.body
    assert routed.metadata == %{user_message_id: "u-1", assistant_message_id: "a-1"}
  end

  defp outgoing do
    %Outgoing{
      body: "delivered",
      channel_id: "channel-1",
      provider: :test,
      metadata: %{
        user_message_id: "u-1",
        assistant_message_id: "a-1",
        trace: "private"
      }
    }
  end
end
