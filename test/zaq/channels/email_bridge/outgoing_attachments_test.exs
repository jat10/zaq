defmodule Zaq.Channels.EmailBridge.OutgoingAttachmentsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.SmtpSender
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.TestSupport.ChannelFileFixtures

  setup :verify_on_exit!

  test "count grouping uses unique email identities and threads continuations under the confirmed root" do
    config = smtp_config("selected@example.test", %{"max_attachments_per_message" => 2})
    files = Enum.map(0..4, &%{file("bytes-#{&1}") | id: "file-#{&1}", name: "file-#{&1}.txt"})

    assert {:ok, %{confirmation: :confirmed, messages: receipts}} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | delivery: %{outgoing(config.id).delivery | attachments: files}
               },
               %{
                 attachment_failure_policy: :continue
               }
             )

    assert Enum.map(receipts, & &1.delivered_attachment_indices) == [[0, 1], [2, 3], [4]]
    assert length(Enum.uniq(Enum.map(receipts, & &1.message_id))) == 3
    assert Enum.all?(tl(receipts), &(&1.thread_id == "sent@example.test"))

    for _ <- 1..3 do
      assert_receive {:email, email}
      assert length(email.attachments) <= 2
      assert email.subject == "Files"

      if email.headers["Message-ID"] != "<sent@example.test>",
        do: assert(email.headers["In-Reply-To"] == "<sent@example.test>")
    end

    refute_received {:email, _}
  end

  test "exact encoded email ceiling accepts the boundary and rejects a body one byte over" do
    config = smtp_config("selected@example.test")

    outgoing = %{
      outgoing(config.id)
      | delivery: %{outgoing(config.id).delivery | attachments: [file("bytes")]}
    }

    connection = %{smtp_config_id: config.id, smtp_settings: config.settings}

    assert {:ok, prepared} =
             EmailBridge.prepare_delivery_message(
               outgoing,
               [
                 %{
                   content: "bytes",
                   name: "report.bin",
                   mime_type: "application/octet-stream",
                   size: 5
                 }
               ],
               connection
             )

    assert is_integer(prepared.encoded_bytes)
    assert prepared.encoded_bytes > 5
    refute_received {:email, _}
    exact = put_in(connection.smtp_settings["max_encoded_message_bytes"], prepared.encoded_bytes)
    assert {:ok, _} = EmailBridge.send_reply(outgoing, exact)
    assert_receive {:email, _}

    too_small =
      put_in(connection.smtp_settings["max_encoded_message_bytes"], prepared.encoded_bytes - 1)

    assert {:error, %{delivery: :not_sent}} = EmailBridge.send_reply(outgoing, too_small)
    refute_received {:email, _}
  end

  test "final continuation headers are remeasured and an oversized email is never submitted" do
    config = smtp_config("selected@example.test", %{"max_attachments_per_message" => 1})

    outgoing = %{
      outgoing(config.id)
      | delivery: %{outgoing(config.id).delivery | attachments: [file("one"), file("two")]}
    }

    connection = %{
      smtp_config_id: config.id,
      smtp_settings: config.settings,
      delivery_group_id: 1,
      attachment_failure_policy: :continue
    }

    files = [
      %{content: "two", name: "report.bin", mime_type: "application/octet-stream", size: 3}
    ]

    assert {:ok, candidate} = EmailBridge.prepare_delivery_message(outgoing, files, connection)

    connection =
      put_in(connection.smtp_settings["max_encoded_message_bytes"], candidate.encoded_bytes)

    assert {:ok, %{confirmation: :partial, messages: [root], failed_attachments: failures}} =
             EmailBridge.send_reply(outgoing, connection)

    assert root.message_id == "sent@example.test"
    assert [%{attachment_index: 1, delivery: :not_sent, stage: :preparation}] = failures
    assert_receive {:email, _}
    refute_received {:email, _}
  end

  test "multiple files preserve bytes, names, MIME types, selected sender, recipients and threading" do
    selected = smtp_config("selected@example.test")
    smtp_config("other@example.test")
    bytes = <<0, 255, 254, 128, 10>>

    outgoing = %{
      outgoing(selected.id)
      | thread_anchor: %{
          "message_id" => "parent@example.test",
          "references" => ["root@example.test"]
        },
        routing_context: %{
          channel_config_id: selected.id,
          reply_targets: %{to: ["recipient@example.test"], cc: ["copied@example.test"]}
        },
        delivery: %{
          outgoing(selected.id).delivery
          | attachments: [
              file(bytes),
              %{file("second") | name: "notes.txt", mime_type: "text/plain"}
            ]
        }
    }

    assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{})
    assert_receive {:email, email}
    assert [first, second] = email.attachments
    assert first.data == bytes
    assert first.filename == "report.bin"
    assert first.content_type == "application/octet-stream"
    assert first.path == nil
    assert second.data == "second"
    assert second.filename == "notes.txt"
    assert second.content_type == "text/plain"
    assert email.from == {"Selected", "selected@example.test"}
    assert email.to == [{"", "recipient@example.test"}]
    assert email.cc == [{"", "copied@example.test"}]
    assert email.headers["Message-ID"] == "<sent@example.test>"
    assert email.headers["In-Reply-To"] == "<parent@example.test>"
    assert email.headers["References"] == "<root@example.test> <parent@example.test>"
    assert receipt.message_id == "sent@example.test"
    assert receipt.confirmation == :confirmed
    assert receipt.audience.sender == "selected@example.test"
    assert receipt.audience.recipients == ["recipient@example.test", "copied@example.test"]
    refute_receive {:email, _}
  end

  property "one attachment reaches the synchronous mailer with every byte intact" do
    config = smtp_config("selected@example.test")

    check all(bytes <- binary(max_length: 2_048), max_runs: 30) do
      assert {:ok, _} =
               EmailBridge.send_reply(
                 %{
                   outgoing(config.id)
                   | delivery: %{outgoing(config.id).delivery | attachments: [file(bytes)]}
                 },
                 %{}
               )

      assert_receive {:email, %{attachments: [attachment]}}
      assert Swoosh.Attachment.get_content(attachment) == bytes
      assert attachment.path == nil
    end
  end

  test "one failed preparation prevents sending already prepared files" do
    config = smtp_config("selected@example.test", %{"send_on_file_failure" => false})

    for invalid <- [file("%%%", %{"encoding" => "base64"}), %{file(nil) | path: "/private/file"}] do
      assert {:error, _} =
               EmailBridge.send_reply(
                 %{
                   outgoing(config.id)
                   | delivery: %{
                       outgoing(config.id).delivery
                       | attachments: [file("ready"), invalid]
                     }
                 },
                 %{}
               )

      refute_receive {:email, _}
    end
  end

  test "explicit continue submits one email with usable files and confirms no failed file" do
    config = smtp_config("selected@example.test")

    outgoing = %{
      outgoing(config.id)
      | delivery: %{
          outgoing(config.id).delivery
          | attachments: [file("ready"), file("%%%", %{"encoding" => "base64"})]
        }
    }

    assert {:ok, %{confirmation: :partial, messages: [receipt], failed_attachments: [_]}} =
             EmailBridge.send_reply(outgoing, %{attachment_failure_policy: :continue})

    assert receipt.confirmation == :confirmed
    assert receipt.delivered_attachment_indices == [0]

    assert receipt.attachments == [
             %{
               "kind" => "file",
               "name" => "report.bin",
               "mime_type" => "application/octet-stream",
               "size" => 5
             }
           ]

    assert_receive {:email, %{attachments: [attachment]}}
    assert Swoosh.Attachment.get_content(attachment) == "ready"
    refute_receive {:email, _}
  end

  test "explicit continue submits one text email when no file can be prepared" do
    config = smtp_config("selected@example.test")

    assert {:ok, %{messages: [%{delivered_attachment_indices: []}]}} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | delivery: %{outgoing(config.id).delivery | attachments: [file(nil)]}
               },
               %{
                 attachment_failure_policy: :continue
               }
             )

    assert_receive {:email, %{attachments: []}}
    refute_receive {:email, _}
  end

  test "explicit abort sends no email after preparation failure" do
    config = smtp_config("selected@example.test", %{"send_on_file_failure" => false})

    assert {:error, %{stage: :preparation, delivery: :not_sent}} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | delivery: %{
                     outgoing(config.id).delivery
                     | attachments: [file("ready"), file(nil)]
                   }
               },
               %{attachment_failure_policy: :abort}
             )

    refute_receive {:email, _}
  end

  test "lazy files carry only trusted context and materialize once before delivery" do
    config = smtp_config("selected@example.test")
    assert {:ok, handle} = DiskDocument.issue("source-file")
    bytes = <<255, 0, 128>>

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{person_id: 123}
      refute Keyword.has_key?(event.opts, :credentials)
      refute_received {:email, _}

      %{
        event
        | response:
            {:ok, %{record: %{file(bytes) | name: "resolved.pdf", mime_type: "application/pdf"}}}
      }
    end)

    details = %{
      trusted_context: %{actor: %{person_id: 123}, credentials: "private"},
      node_router: Zaq.NodeRouterMock
    }

    assert {:ok, _} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | delivery: %{
                     outgoing(config.id).delivery
                     | attachments: [%{file(nil) | materialization_handle: handle}]
                   }
               },
               details
             )

    assert_receive {:email, %{attachments: [attachment]}}
    assert Swoosh.Attachment.get_content(attachment) == bytes
    assert attachment.filename == "resolved.pdf"
    assert attachment.content_type == "application/pdf"
  end

  test "malformed internal prepared payloads are rejected without sending or reading paths" do
    config = smtp_config("selected@example.test")

    for attachments <- [
          nil,
          %{},
          ["/private/file"],
          [%{path: "/private/file"}],
          [%{content: 12, name: "x", mime_type: "text/plain", size: 1}]
        ] do
      assert {:error, :invalid_prepared_attachment} =
               SmtpSender.send_notification_with_receipt(
                 "recipient@example.test",
                 %{"body" => "hello", "attachments" => attachments},
                 %{},
                 config.id
               )

      refute_receive {:email, _}
    end
  end

  test "SMTP rejection propagates without a confirmed receipt or fallback send" do
    config =
      smtp_config("selected@example.test", %{
        "relay" => "127.0.0.1",
        "port" => "1",
        "tls" => "never"
      })

    assert {:error, _} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | delivery: %{outgoing(config.id).delivery | attachments: [file(<<255, 0>>)]}
               },
               %{}
             )

    refute_receive {:email, _}
  end

  defp outgoing(config_id) do
    %Outgoing{
      provider: :"email:smtp",
      channel_id: "recipient@example.test",
      body: "hello",
      routing_context: %{channel_config_id: config_id},
      metadata: %{"subject" => "Files", "threading" => %{"message_id" => "sent@example.test"}}
    }
  end

  defp file(content, attributes \\ %{}) do
    %Record{
      id: "source-file",
      kind: :file,
      content: content,
      name: "report.bin",
      mime_type: "application/octet-stream",
      attributes: attributes
    }
  end

  defp smtp_config(address, overrides \\ %{}) do
    ChannelFileFixtures.config!("email:smtp", address, %{
      name: address,
      url: "smtp.example.test",
      token: "fixture-token",
      settings:
        Map.merge(
          %{
            "relay" => "",
            "from_email" => address,
            "from_name" => "Selected",
            "max_encoded_message_bytes" => 10_000_000,
            "max_attachments_per_message" => 10
          },
          overrides
        )
    })
  end
end
