defmodule Zaq.ConnectorConfig.EncodedTextLimitTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EmailBridge
  alias Zaq.ConnectorConfig.FileSettings

  test "a valid text ceiling is independent of missing or malformed discarded file limits" do
    assert {:ok, snapshot} = EmailBridge.capability_snapshot(%{provider: "email:smtp"})

    assert {:ok, 2_000} =
             FileSettings.encoded_message_limit(
               %{
                 "max_encoded_message_bytes" => 2_000,
                 "max_attachments_per_message" => "invalid"
               },
               snapshot
             )

    for value <- [nil, -1, 0, "2000", false] do
      assert {:error, :invalid_encoded_message_limit} =
               FileSettings.encoded_message_limit(
                 %{"max_encoded_message_bytes" => value},
                 snapshot
               )
    end

    assert {:error, :invalid_encoded_message_limit} =
             FileSettings.encoded_message_limit(%{}, snapshot)
  end

  test "unknown optional ceilings remain unknown and configured ceilings cannot exceed declared limits" do
    assert {:ok, :unresolved} =
             FileSettings.encoded_message_limit(%{}, %{resolved: %{text: :native}})

    snapshot = %{
      resolved: %{text: :native, file: :native},
      file_delivery: %{
        transfer_mode: :upload_then_publish,
        supports_attachment_edits: false,
        limits: %{
          max_encoded_message_bytes: %{value: 100, configurable: true, required: false}
        }
      }
    }

    assert {:ok, 100} = FileSettings.encoded_message_limit(%{}, snapshot)

    assert {:ok, 50} =
             FileSettings.encoded_message_limit(%{"max_encoded_message_bytes" => 50}, snapshot)

    assert {:error, :invalid_encoded_message_limit} =
             FileSettings.encoded_message_limit(%{"max_encoded_message_bytes" => 101}, snapshot)
  end
end
