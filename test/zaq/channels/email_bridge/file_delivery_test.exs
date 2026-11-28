defmodule Zaq.Channels.EmailBridge.FileDeliveryTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Delivery.{Attachments, Executor, Preparation, Result}
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.SmtpSender
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  test "selected SMTP preparation measures the exact final MIME and submits it once" do
    connection = connection()
    outgoing = outgoing()
    assert {:ok, prepared} = EmailBridge.prepare_delivery_message(outgoing, files(), connection)
    assert prepared.size_bytes == byte_size(prepared.request.body)
    assert :ok = Preparation.validate_request(prepared, prepared.size_bytes)

    assert {:error, :encoded_request_too_large} =
             Preparation.validate_request(prepared, prepared.size_bytes - 1)

    refute_received :smtp_connection

    assert {:ok, %{confirmation: :confirmed, source_scope: "smtp:confirmed"}} =
             EmailBridge.execute_delivery_step(
               %{operation: :send},
               %{prepared: prepared},
               connection
             )

    assert_receive :smtp_connection
    assert_receive {:smtp_data, wire}
    assert wire == Regex.replace(~r/^\./m, prepared.request.body, "..") <> "\r\n"
    assert wire =~ "Message-ID: <"
    assert wire =~ "application/octet-stream"
    refute_receive :smtp_connection, 50
  end

  test "real SMTP executor acquires binary records and confirms relay submission" do
    connection = connection()
    assert {:ok, snapshot} = EmailBridge.capability_snapshot(connection)
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    assert {:ok, plan} = Attachments.build_plan(outgoing(), requirements)
    assert {:ok, result} = Executor.execute(outgoing(), plan, EmailBridge, connection)

    assert [%{confirmation: :confirmed, audience: %{sender: "frozen@example.com"}}] =
             Result.confirmed_receipts(result)

    assert_receive {:smtp_command, "MAIL FROM:<frozen@example.com>\r\n"}
    assert_receive {:smtp_command, "RCPT TO:<recipient@example.com>\r\n"}
    assert_receive {:smtp_data, _}
  end

  test "abort validates all MIME candidates before making any SMTP connection" do
    connection = connection()

    outgoing = %{
      outgoing()
      | attachments: [record("small", "a"), record("large", String.duplicate("x", 1_800))]
    }

    connection =
      put_in(connection.settings["file_delivery"], %{
        "max_attachments_per_message" => 1,
        "max_encoded_message_bytes" => 3_000,
        "send_on_file_failure" => false
      })

    assert {:ok, snapshot} = EmailBridge.capability_snapshot(connection)
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    assert {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    assert {:error, _, result} = Executor.execute(outgoing, plan, EmailBridge, connection)
    assert Result.confirmed_receipts(result) == []
    refute_received :smtp_connection
  end

  test "malformed prepared input cannot select paths, URLs or a different envelope" do
    assert {:error, _} = SmtpSender.send_prepared(%{body: "file:///etc/passwd", config: []})
    connection = connection()

    assert {:error, _} =
             EmailBridge.prepare_delivery_message(
               outgoing(),
               [%{path: "/etc/passwd"}],
               connection
             )

    refute_received :smtp_connection
  end

  test "the first reply preserves the immediate parent within an existing email thread" do
    outgoing = %{
      outgoing()
      | thread_id: "thread-root@example.com",
        in_reply_to: "immediate-parent@example.com"
    }

    assert {:ok, prepared} = EmailBridge.prepare_delivery_message(outgoing, files(), connection())
    assert prepared.request.body =~ "In-Reply-To: <immediate-parent@example.com>"
  end

  test "a continuation receives a new MIME identity instead of reusing a preminted answer ID" do
    outgoing = %{
      outgoing()
      | thread_id: "answer-root@example.com",
        metadata: %{"threading" => %{"message_id" => "answer-root@example.com"}}
    }

    connection = Map.put(connection(), :delivery_continuation?, true)
    assert {:ok, prepared} = EmailBridge.prepare_delivery_message(outgoing, files(), connection)
    refute prepared.receipt.message_id == "answer-root@example.com"
    assert prepared.request.body =~ "In-Reply-To: <answer-root@example.com>"
  end

  test "abort preserves the first submission when final continuation headers exceed the measured ceiling" do
    connection = connection()

    original = %{
      outgoing()
      | attachments: [record("first", "x"), record("second", "y")],
        metadata: %{"threading" => %{"message_id" => "answer-root@example.com"}}
    }

    files = [%{hd(files()) | content: "x", size: 1}]
    assert {:ok, first} = EmailBridge.prepare_delivery_message(original, files, connection)
    prototype = %{original | body: "Additional files (2/2).", attachments: []}

    assert {:ok, later} =
             EmailBridge.prepare_delivery_message(
               prototype,
               files,
               Map.put(connection, :delivery_continuation?, true)
             )

    limit = max(first.size_bytes, later.size_bytes) + 1

    connection =
      put_in(connection.settings["file_delivery"], %{
        "max_attachments_per_message" => 1,
        "max_encoded_message_bytes" => limit,
        "send_on_file_failure" => false
      })

    assert {:ok, snapshot} = EmailBridge.capability_snapshot(connection)
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    assert {:ok, plan} = Attachments.build_plan(original, requirements)
    assert {:ok, result} = Executor.execute(original, plan, EmailBridge, connection)
    assert [%{message_id: "answer-root@example.com"}] = Result.confirmed_receipts(result)
    assert {:ok, evidence} = Result.safe_evidence(result)
    assert Enum.any?(evidence.parts, &(&1.group_id == 1 and &1.stage == :preparation))
    assert_receive :smtp_connection
    assert_receive {:smtp_data, _}
    refute_receive :smtp_connection, 50
  end

  test "required SMTP limits are never fabricated and IMAP settings cannot authorize SMTP delivery" do
    assert {:ok, snapshot} =
             EmailBridge.capability_snapshot(%{provider: "email:smtp", settings: %{}})

    assert {:error, {:invalid_configuration, errors}} =
             TransportRequirements.resolve(snapshot, %{settings: %{}})

    assert errors["max_attachments_per_message"]
    assert errors["max_encoded_message_bytes"]
    assert {:ok, imap} = EmailBridge.capability_snapshot(%{provider: "email:imap", settings: %{}})
    assert {:error, :unsupported} = TransportRequirements.resolve(imap, %{settings: %{}})
  end

  test "final reply headers are re-encoded and a changed connection cannot redirect a prepared envelope" do
    connection = connection()
    assert {:ok, initial} = EmailBridge.prepare_delivery_message(outgoing(), files(), connection)
    threaded = %{outgoing() | thread_id: String.duplicate("parent", 100) <> "@example.com"}

    assert {:ok, final} =
             EmailBridge.prepare_delivery_message(
               threaded,
               files(),
               Map.put(connection, :delivery_continuation?, true)
             )

    assert final.size_bytes > initial.size_bytes

    assert {:error, :encoded_request_too_large} =
             Preparation.validate_request(final, initial.size_bytes)

    assert final.request.body =~ "In-Reply-To:"

    changed = %{
      connection
      | settings: %{"relay" => "invalid.example", "from_email" => "other@example.com"}
    }

    assert {:ok, _} =
             EmailBridge.execute_delivery_step(%{operation: :send}, %{prepared: final}, changed)

    assert_receive {:smtp_command, "MAIL FROM:<frozen@example.com>\r\n"}
    assert_receive {:smtp_data, wire}
    assert wire == Regex.replace(~r/^\./m, final.request.body, "..") <> "\r\n"
  end

  test "prepared SMTP has one host, zero retries and no opportunistic TLS retry" do
    connection = put_in(connection().settings["tls"], "enabled")
    assert {:ok, prepared} = EmailBridge.prepare_delivery_message(outgoing(), [], connection)
    assert prepared.request.config[:retries] == 0
    assert prepared.request.config[:no_mx_lookups] == true
    assert prepared.request.config[:tls] == :always
    refute inspect(prepared.request) =~ "frozen@example.com"
    refute_received :smtp_connection
  end

  test "negative SMTP acknowledgment is rejected while a lost acknowledgment remains unconfirmed; neither retries" do
    for {response, outcome} <- [{"451 temporary rejection\r\n", :failed}, {:close, :unconfirmed}] do
      connection = connection(response: response)

      assert {:ok, prepared} =
               EmailBridge.prepare_delivery_message(outgoing(), files(), connection)

      assert {:error, %{outcome: ^outcome}} =
               EmailBridge.execute_delivery_step(
                 %{operation: :send},
                 %{prepared: prepared},
                 connection
               )

      assert_receive :smtp_connection
      assert_receive {:smtp_data, _}
      refute_receive :smtp_connection, 50
    end
  end

  defp connection(opts \\ []) do
    pid = start_supervised!({Zaq.Test.SmtpCapture, Keyword.put(opts, :owner, self())})
    assert_receive {:smtp_listening, ^pid, port}

    %{
      provider: "email:smtp",
      id: 42,
      settings: %{
        "relay" => "127.0.0.1",
        "port" => Integer.to_string(port),
        "tls" => "never",
        "from_email" => "frozen@example.com",
        "file_delivery" => %{
          "max_attachments_per_message" => 2,
          "max_encoded_message_bytes" => 20_000
        }
      }
    }
  end

  defp outgoing,
    do: %Outgoing{
      provider: :"email:imap",
      channel_id: "recipient@example.com",
      body: "answer",
      attachments: [record("file", <<0, 255>>)]
    }

  defp record(id, content),
    do: %Record{
      id: id,
      kind: :file,
      name: "résumé.bin",
      mime_type: "application/octet-stream",
      size: byte_size(content),
      content: content
    }

  defp files,
    do: [
      %{
        index: 0,
        name: "résumé.bin",
        mime_type: "application/octet-stream",
        size: 2,
        content: <<0, 255>>
      }
    ]
end
