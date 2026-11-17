defmodule Zaq.ConnectorConfig.SettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.{ImapSettings, Settings, SmtpSettings}

  test "SMTP unit conversion preserves precision beyond Decimal's arithmetic context" do
    bytes = 123_456_789_012_345_678_901_234_567_890_123_456_789
    assert bytes == bytes |> SmtpSettings.message_megabytes() |> SmtpSettings.message_bytes()

    assert SmtpSettings.whole_message_bytes?(
             Decimal.new(1, 123_456_789_012_345_678_901_234_567_890_123_456, -6)
           )

    refute SmtpSettings.whole_message_bytes?(
             Decimal.new(1, 1_234_567_890_123_456_789_012_345_678_901_234_567, -7)
           )
  end

  property "SMTP decimal MB conversion preserves every configured byte" do
    check all(bytes <- integer(1..1_000_000_000)) do
      assert bytes == bytes |> SmtpSettings.message_megabytes() |> SmtpSettings.message_bytes()
    end

    assert SmtpSettings.message_bytes(nil) == nil
    assert SmtpSettings.message_megabytes(nil) == nil

    assert SmtpSettings.map_get(
             %{max_encoded_message_bytes: 1_234_567},
             "max_encoded_message_bytes"
           ) == 1_234_567

    assert SmtpSettings.map_get(%{max_files_per_message: 3}, "max_files_per_message") == 3
  end

  property "IMAP top-level values, including false and nil, override nested defaults" do
    check all(
            value <- one_of([integer(), string(:printable), boolean(), constant(nil)]),
            nested <- string(:printable)
          ) do
      for key <- [:username, "username"] do
        config = %{key => value, settings: %{"imap" => %{"username" => nested}}}
        assert ImapSettings.get(config, key, :missing) == value
      end
    end
  end

  test "shared helpers preserve atom/string lookup and malformed-input behavior" do
    assert ImapSettings.get(%{settings: %{imap: %{ssl: false}}}, :ssl, true) == false
    assert ImapSettings.get(nil, :username, :missing) == :missing
    assert SmtpSettings.map_get(%{relay: "smtp.example.com"}, "relay") == "smtp.example.com"

    assert SmtpSettings.map_get(%{"relay" => "explicit", relay: "fallback"}, "relay") ==
             "explicit"

    assert Settings.jido_chat_setting(%{settings: %{"jido_chat" => nil}}, "bot_name", "zaq") ==
             "zaq"

    assert Settings.imap_selected_mailboxes(%{
             settings: %{"imap" => %{"selected_mailboxes" => [nil, " INBOX ", ""]}}
           }) == ["INBOX"]
  end

  test "connector policy defaults on and preserves explicit boolean and form false" do
    assert Settings.attachment_failure_policy(%{}) == :continue

    for value <- [false, "false"] do
      assert Settings.attachment_failure_policy(%{settings: %{"send_on_file_failure" => value}}) ==
               :abort
    end

    for value <- [true, "true", nil] do
      assert Settings.attachment_failure_policy(%{settings: %{"send_on_file_failure" => value}}) ==
               :continue
    end
  end
end
