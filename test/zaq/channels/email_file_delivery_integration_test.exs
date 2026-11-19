defmodule Zaq.Channels.EmailFileDeliveryIntegrationTest do
  @moduledoc "Authorized Disk -> Outgoing -> real SMTP composition -> raw MIME stub capture."
  use Zaq.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Channels.Api
  alias Zaq.Channels.Delivery.Error
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.TestSupport.ChannelFileDelivery
  alias Zaq.TestSupport.ChannelFileFixtures
  alias Zaq.TestSupport.FileDeliverySmtpStub

  @moduletag timeout: 180_000

  test "failed MIME preparation cannot fall through to an unrestricted ordinary text send" do
    namespace = "oversized-#{Ecto.UUID.generate()}"
    port = FileDeliverySmtpStub.start!(self(), namespace)

    config =
      smtp_connector!(namespace, %{
        "relay" => "127.0.0.1",
        "port" => to_string(port),
        "tls" => "never",
        "from_email" => "sender@example.test",
        "max_encoded_message_bytes" => 1,
        "max_attachments_per_message" => 1
      })

    outgoing = %Outgoing{
      provider: :"email:smtp",
      channel_id: "recipient@example.test",
      body: "Original answer",
      routing_context: %{channel_config_id: config.id},
      delivery: %Outgoing.Delivery{
        attachments: [%Record{id: "file", kind: :file, content: "bytes"}]
      }
    }

    task =
      Task.async(fn ->
        receive do
          :deliver ->
            Api.handle_event(Event.new(outgoing, :channels), :deliver_outgoing, nil).response
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :deliver)

    try do
      assert {:error, %Error{delivery: :not_sent}} = Task.await(task, 5000)
      refute_received {:delivery_boundary, ^namespace, _, _}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "only the selected signed Disk Record reaches the captured SMTP envelope" do
    ChannelFileDelivery.run!([:email])
  end

  test "an empty attachment collection produces an SMTP message without MIME attachments" do
    ChannelFileDelivery.run!([:email], files: false)
  end

  test "two SMTP journeys overlap without crossed files, recipients or cleanup" do
    ChannelFileDelivery.run!([:email, :email])
  end

  for {setting, continue?} <- [{true, true}, {false, false}, {:missing, true}] do
    @failure_setting setting
    @continue_delivery continue?

    test "saved SMTP attachment policy #{inspect(@failure_setting)} controls one real MIME submission" do
      owner = self()
      namespace = "smtp-policy-#{Ecto.UUID.generate()}"
      port = FileDeliverySmtpStub.start!(owner, namespace, connections: 2)

      settings = %{
        "max_encoded_message_bytes" => 10_000_000,
        "max_attachments_per_message" => 10,
        "relay" => "127.0.0.1",
        "port" => to_string(port),
        "tls" => "never",
        "from_email" => "selected@example.test",
        "from_name" => "Selected"
      }

      settings =
        if @failure_setting == :missing,
          do: settings,
          else: Map.put(settings, "send_on_file_failure", @failure_setting)

      config = smtp_connector!(namespace, settings)

      smtp_connector!(namespace <> "-other", %{
        "max_encoded_message_bytes" => 10_000_000,
        "max_attachments_per_message" => 10,
        "relay" => "127.0.0.1",
        "port" => "1",
        "from_email" => "other@example.test",
        "send_on_file_failure" => false
      })

      {:ok, person} = People.create_person(%{full_name: namespace})
      bytes = <<0, 255, 128, 10>>

      files = [
        %Record{
          id: "usable",
          kind: :file,
          name: "usable.bin",
          mime_type: "application/octet-stream",
          content: bytes
        },
        %Record{
          id: "failed",
          kind: :file,
          name: "failed.bin",
          content: "%%%",
          attributes: %{"encoding" => "base64"}
        }
      ]

      imap =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: namespace <> "-inbox",
          provider: "email:imap",
          kind: "retrieval",
          enabled: true,
          url: "imap://fixture",
          token: "synthetic-unused",
          settings: %{
            "imap" => %{"smtp_config_id" => config.id, "selected_mailboxes" => ["INBOX"]},
            "send_on_file_failure" => not @continue_delivery
          }
        })
        |> Repo.insert!()

      for {provider, route} <- [{:"email:smtp", config}, {:"email:imap", imap}] do
        outgoing = %Outgoing{
          provider: provider,
          channel_id: "recipient@example.test",
          body: "Original answer",
          routing_context: %{
            channel_config_id: route.id,
            reply_targets: %{to: ["recipient@example.test"], cc: ["copied@example.test"]}
          },
          metadata: %{
            "subject" => "Attachment policy",
            "threading" => %{"message_id" => "#{namespace}@example.test"}
          },
          delivery: %Outgoing.Delivery{attachments: files}
        }

        assert_policy_delivery!(outgoing, %{person_id: person.id}, namespace, @continue_delivery)
        assert outgoing.delivery.attachments == files
      end
    end
  end

  defp assert_policy_delivery!(outgoing, actor, namespace, continue?) do
    owner = self()

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:smtp_policy_confirmation, event})
      %{event | response: {:ok, event.request.receipt}}
    end)

    event =
      Event.new(outgoing, :channels,
        actor: actor,
        opts: [action: :deliver_outgoing, delivery_node_router: Zaq.NodeRouterMock]
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

    try do
      if continue? do
        assert_smtp_accepted!(task, outgoing, namespace)
      else
        assert {:error,
                %Error{
                  reason: :invalid_attachment_base64,
                  stage: :preparation,
                  delivery: :not_sent
                }} = Task.await(task, 5_000)
      end

      refute_received {:delivery_boundary, ^namespace, _, _}
      refute_received {:smtp_policy_confirmation, _}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp assert_smtp_accepted!(task, outgoing, namespace) do
    assert_receive {:delivery_boundary, ^namespace, smtp, capture}, 5_000
    assert capture.sender == "selected@example.test"
    assert Enum.sort(capture.recipients) == ["copied@example.test", "recipient@example.test"]
    mail = Mail.parse(capture.raw)
    assert mail.headers["subject"] == "Attachment policy"
    assert Mail.get_text(mail).body == outgoing.body

    assert Mail.get_attachments(mail) == [
             {"usable.bin", hd(outgoing.delivery.attachments).content}
           ]

    send(smtp, :accept_delivery)

    assert {:ok,
            %{
              confirmation: :partial,
              messages: [%{confirmation: :confirmed}],
              failed_attachments: [failure]
            } = report} = Task.await(task, 5_000)

    assert failure == %{
             attachment_index: 1,
             stage: :preparation,
             delivery: :not_sent,
             reason: "The attachment contains invalid Base64 content."
           }

    refute inspect(report) =~ "%%%"
    assert_received {:smtp_policy_confirmation, confirmation}

    assert [%Record{id: "usable", content: nil}] =
             confirmation.request.outgoing.delivery.attachments

    assert confirmation.request.outgoing.routing_context.channel_config_id ==
             outgoing.routing_context.channel_config_id
  end

  defp smtp_connector!(name, settings) do
    ChannelFileFixtures.config!("email:smtp", name, %{
      name: name,
      url: "smtp://127.0.0.1",
      token: "synthetic-unused",
      settings: settings
    })
  end
end
