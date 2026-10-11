defmodule Zaq.Channels.LinkedDevice.WhatsAppIncomingTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.JidoChatBridge.Incoming
  alias Zaq.Channels.JidoChatBridge.Incoming.WhatsApp

  test "privacy identity matches only the receiving profile's trusted alias" do
    message = incoming(%{to_jid: "123:7@s.whatsapp.net", mentions: ["987@lid"]})
    refute message.was_mentioned
    assert WhatsApp.prepare(message, ["123@s.whatsapp.net", "987:1@lid"]).was_mentioned
    refute WhatsApp.prepare(message, ["456@s.whatsapp.net", "654@lid"]).was_mentioned
  end

  test "group mention selects the receiving account and ignores another account" do
    for {recipient, expected} <- [{"123:7@s.whatsapp.net", true}, {"456@s.whatsapp.net", false}] do
      incoming = incoming(%{to_jid: recipient, mentions: ["123@s.whatsapp.net"]})
      assert incoming.was_mentioned == expected
      assert [mention] = incoming.mentions
      assert mention.is_self == expected
      refute incoming.author.is_me
    end
  end

  test "self messages and quoted messages retain distinct facts" do
    incoming = incoming(%{from_me: true, quoted: %{id: "original"}})
    assert incoming.author.is_me
    refute incoming.was_mentioned
    assert incoming.external_reply_to_id == "original"
  end

  test "room identity is evidenced and unknown broadcasts remain unknown" do
    for {room, expected} <- [
          {"room@g.us", :room},
          {"123@s.whatsapp.net", :one_to_one},
          {"123@lid", :one_to_one}
        ] do
      message = incoming(%{channel_jid: room})
      facts = Incoming.normalize(message, :whatsapp, Adapter)
      assert facts.conversation_type == expected
      assert facts.source_scope == room
      assert facts.sender_id == "peer@s.whatsapp.net"
    end

    message = incoming(%{channel_jid: "status@broadcast"})
    assert Incoming.normalize(message, :whatsapp, Adapter) == %{}
  end

  test "missing recipient never invents a self mention" do
    refute incoming(%{to_jid: nil, mentions: ["123@s.whatsapp.net"]}).was_mentioned
  end

  defp incoming(overrides) do
    payload =
      Map.merge(
        %{
          id: "message-1",
          channel_jid: "room@g.us",
          from_jid: "peer@s.whatsapp.net",
          to_jid: "123@s.whatsapp.net",
          text: "hello",
          timestamp: 1_760_000_000
        },
        overrides
      )

    {:ok, incoming} = Adapter.transform_incoming(payload)
    Incoming.prepare(incoming, :whatsapp)
  end
end
