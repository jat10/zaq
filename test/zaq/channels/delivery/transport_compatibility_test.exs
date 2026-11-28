defmodule Zaq.Channels.Delivery.TransportCompatibilityTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Adapter, FileUpload}
  alias Swoosh.Adapters.SMTP
  alias Swoosh.Adapters.SMTP.Helpers
  alias Zaq.Channels.{JidoChatBridge, TransportRequirements}

  test "the controlled external adapter exposes exact preparation and confirmed upload, send and edit shapes" do
    adapter = Zaq.Test.FileDeliveryAdapter
    opts = [token: self()]

    files = [
      FileUpload.new(%{
        data: <<0, 255>>,
        filename: "binary.dat",
        media_type: "application/octet-stream"
      })
    ]

    assert {:ok, prepared} = adapter.prepare_upload("channel", files, opts)
    assert prepared.size_bytes == byte_size(prepared.body)
    refute_received {:adapter_upload, _}
    assert {:ok, %{files: [%{id: "uploaded-0"}]}} = adapter.upload_prepared(prepared, opts)

    assert {:ok, %{external_message_id: id}} =
             Adapter.send_message(adapter, "channel", "answer", opts)

    assert is_binary(id)

    assert {:ok, %{external_message_id: ^id, status: :edited}} =
             adapter.edit_message("channel", id, "updated", opts)

    assert_receive {:adapter_upload, ^prepared}
    assert_receive {:adapter_send, "channel", "answer", ^opts}
    assert_receive {:adapter_edit, "channel", ^id, "updated", ^opts}
  end

  test "pinned chat packages cannot enter the file executor without declarations and primitives" do
    for {provider, adapter} <- [
          mattermost: Jido.Chat.Mattermost.Adapter,
          telegram: Jido.Chat.Telegram.Adapter
        ] do
      Code.ensure_loaded!(adapter)
      refute function_exported?(adapter, :file_requirements, 0)
      refute function_exported?(adapter, :prepare_upload, 3)
      refute function_exported?(adapter, :upload_prepared, 2)
      connection = %{provider: provider, settings: %{}}
      assert {:ok, snapshot} = JidoChatBridge.capability_snapshot(connection)

      assert {:error, :capabilities_unavailable} =
               TransportRequirements.resolve(snapshot, connection)
    end
  end

  test "the pinned SMTP stack submits the same encoded MIME with only SMTP dot framing" do
    config = capture()

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from("sender@example.com")
      |> Swoosh.Email.to("recipient@example.com")
      |> Swoosh.Email.subject("Files ü")
      |> Swoosh.Email.header("Message-ID", "<stable@example.com>")
      |> Swoosh.Email.text_body("answer\r\n.line\r\nlast")
      |> Swoosh.Email.attachment(
        Swoosh.Attachment.new({:data, <<0, 255, 13, 10>>},
          filename: "résumé.bin",
          content_type: "application/octet-stream"
        )
      )

    encoded = Helpers.body(email, config)
    assert is_binary(encoded)
    assert byte_size(encoded) > 4
    assert encoded =~ "Message-ID: <stable@example.com>"

    assert is_binary(
             :gen_smtp_client.send_blocking(
               {Helpers.sender(email), ["recipient@example.com"], encoded},
               SMTP.gen_smtp_config(config)
             )
           )

    assert_receive :smtp_connection
    assert_receive {:smtp_data, submitted}
    assert submitted == Regex.replace(~r/^\./m, encoded, "..") <> "\r\n"
    refute String.contains?(String.replace(encoded, "\r\n", ""), "\n")
    refute_receive :smtp_connection, 100
  end

  test "a temporary SMTP submission rejection is not retried when retries is zero" do
    config = capture(response: "451 temporary rejection\r\n")

    assert {:error, _, _} =
             :gen_smtp_client.send_blocking(
               {"sender@example.com", ["recipient@example.com"], "Subject: test\r\n\r\nbody"},
               SMTP.gen_smtp_config(config)
             )

    assert_receive :smtp_connection
    assert_receive {:smtp_data, _}
    refute_receive :smtp_connection, 100
  end

  defp capture(opts \\ []) do
    pid = start_supervised!({Zaq.Test.SmtpCapture, Keyword.put(opts, :owner, self())})
    assert_receive {:smtp_listening, ^pid, port}
    [relay: "127.0.0.1", port: port, tls: :never, auth: :never, retries: 0, no_mx_lookups: true]
  end
end
