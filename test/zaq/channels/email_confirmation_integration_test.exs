defmodule Zaq.Channels.EmailConfirmationIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.TestSupport.ChannelFileFixtures, only: [connector!: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Channels.Api
  alias Zaq.Contracts.Record
  alias Zaq.Engine.{Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.{Message, TranscriptMessage}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.TestSupport.FileDeliverySmtpStub

  defmodule BridgeResolver do
    def bridge_for(_provider), do: Zaq.Channels.EmailBridge
    defdelegate fetch_connection_details_for_config(config), to: Zaq.Channels.Bridge
  end

  for scenario <- [:normal, :selection_failure, :stale_metadata, :missing_metadata] do
    @scenario scenario

    test "#{scenario} SMTP confirmation preserves canonical history and sent file metadata" do
      owner = self()
      namespace = Ecto.UUID.generate()
      port = FileDeliverySmtpStub.start!(owner, namespace)

      smtp =
        connector!("email:smtp", %{
          "relay" => "127.0.0.1",
          "port" => to_string(port),
          "tls" => "never",
          "from_email" => "sender@example.test",
          "max_encoded_message_bytes" => 10_000_000,
          "max_attachments_per_message" => 10,
          "send_on_file_failure" => true
        })

      imap =
        connector!("email:imap", %{
          "imap" => %{"smtp_config_id" => smtp.id, "selected_mailboxes" => ["INBOX"]}
        })

      {:ok, person} =
        People.find_or_create_from_channel("email", %{
          channel_id: "recipient@example.test",
          channel_config_id: imap.id,
          display_name: namespace
        })

      routing = %{
        channel_config_id: imap.id,
        conversation_type: :recipient_addressed,
        conversation_id: "recipient@example.test",
        source_scope: "INBOX",
        identity_platform: "email",
        audience: %{
          platform: "email",
          sender: "recipient@example.test",
          recipients: ["sender@example.test"]
        }
      }

      incoming =
        Incoming.new(%{
          provider: :"email:imap",
          channel_id: "recipient@example.test",
          author_id: "recipient@example.test",
          message_id: namespace,
          content: "Send the files",
          person: person,
          routing_context: routing
        })

      assert {:ok, _} = HistoryIngress.capture(incoming)
      assert {:ok, binding} = Conversations.admit_incoming(incoming)

      assert {:ok, %{assistant_message_id: assistant_id}} =
               Conversations.finalize_incoming(
                 binding.user_message_id,
                 binding.finalization_token,
                 %{answer: "Original answer", error: false},
                 actor: %{person: %{id: person.id}}
               )

      outgoing = %Outgoing{
        provider: :"email:imap",
        channel_id: "recipient@example.test",
        body: "Original answer",
        routing_context:
          Map.put(routing, :reply_targets, %{to: ["recipient@example.test"], cc: []}),
        metadata: %{
          user_message_id: binding.user_message_id,
          assistant_message_id: assistant_id,
          persisted_assistant_message_id: assistant_id
        },
        delivery: %Outgoing.Delivery{
          error: if(@scenario == :selection_failure, do: :invalid_attachment_selection),
          attachments: attachments(@scenario)
        }
      }

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(owner, {:confirmation_request, event.request})
        result = Zaq.Engine.Api.handle_event(event, :record_delivery_confirmation, nil)
        send(owner, {:recorded_confirmation, result.response})
        result
      end)

      event =
        Event.new(outgoing, :channels,
          actor: %{person_id: person.id},
          opts: [
            action: :deliver_outgoing,
            bridge_module: BridgeResolver,
            delivery_node_router: Zaq.NodeRouterMock
          ]
        )

      task =
        Task.async(fn ->
          receive do
            :deliver -> Api.handle_event(event, :deliver_outgoing, nil).response
          end
        end)

      Sandbox.allow(Repo, owner, task.pid)
      allow(Zaq.NodeRouterMock, owner, task.pid)
      send(task.pid, :deliver)

      assert_receive {:delivery_boundary, ^namespace, transport, capture}, 5_000
      assert capture.sender == "sender@example.test"
      assert capture.recipients == ["recipient@example.test"]
      mail = Mail.parse(capture.raw)

      expected_body = "Original answer"

      assert Mail.get_text(mail).body == expected_body

      expected_files =
        case @scenario do
          :stale_metadata -> [{"sent.bin", <<0, 255, 128, 10>>}]
          :missing_metadata -> [{"attachment", <<0, 255, 128, 10>>}]
          _ -> []
        end

      assert Mail.get_attachments(mail) == expected_files
      refute_received {:recorded_confirmation, _}
      send(transport, :accept_delivery)
      result = Task.await(task, 5_000)

      assert {:ok, %{confirmation: :confirmed}} = result

      assert_receive {:recorded_confirmation, {:ok, %{history_capture: :stored}}}, 5_000
      assert_received {:confirmation_request, confirmation}
      assert confirmation.outgoing.delivery.plan == nil
      refute Map.has_key?(confirmation.receipt, :delivered_attachment_indices)
      assert Enum.all?(confirmation.outgoing.delivery.attachments, &is_nil(&1.content))
      assert length(confirmation.outgoing.delivery.attachments) == length(expected_files)
      message = Repo.get!(Message, assistant_id)
      assert message.content == outgoing.body
      assert message.metadata["delivery_confirmation"]["message_id"]
      assert Repo.exists?(from tm in TranscriptMessage, where: tm.message_id == ^assistant_id)

      persisted = Jason.encode!(%{metadata: message.metadata, attachments: message.attachments})
      refute persisted =~ "delivery_plan"
      refute persisted =~ "prepared"
      refute persisted =~ "private"
      refute persisted =~ "source-file"
      refute persisted =~ Base.encode64(<<0, 255, 128, 10>>)

      case expected_files do
        [{name, _bytes}] ->
          assert capture.raw =~ "application/octet-stream"

          assert [%{"name" => ^name, "mime_type" => "application/octet-stream", "size" => 4}] =
                   message.attachments

          refute Jason.encode!(message.attachments) =~ "private"
          refute Jason.encode!(message.attachments) =~ "source-file"
          refute Enum.any?(message.attachments, &Map.has_key?(&1, "id"))
          refute Enum.any?(message.attachments, &Map.has_key?(&1, "content"))

        [] ->
          assert message.attachments == []
      end
    end
  end

  defp attachments(:stale_metadata),
    do: [
      %Record{
        id: "source-file",
        kind: :file,
        name: "sent.bin",
        mime_type: "application/octet-stream",
        size: 999,
        content: <<0, 255, 128, 10>>,
        path: "/private/source",
        raw: %{token: "private"}
      }
    ]

  defp attachments(:missing_metadata),
    do: [
      %Record{
        id: "source-file",
        kind: :file,
        content: <<0, 255, 128, 10>>
      }
    ]

  defp attachments(_), do: []
end
