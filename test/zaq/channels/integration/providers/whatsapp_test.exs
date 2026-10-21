defmodule Zaq.Channels.Integration.Providers.WhatsAppTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.TestSupport.WhatsAppFlowAdapter, as: Adapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  test "headless pairing uses real storage and native direct input reaches the agent" do
    session = channel_session(:whatsapp, llm_answer: "WhatsApp answer")

    assert {:ok, %{phase: :connected, qr: nil}} =
             JidoChatBridge.channel_ingress_status(session.connector)

    emission = emit_message(session, :direct, content: "WhatsApp question")
    result = await_exchange(session, emission)
    assert {:ok, %{confirmation: :confirmed, message_id: id}} = result.event.response

    assert Transport.mailbox()[{session.handle.opaque.profile, emission.channel_id, id}] ==
             "WhatsApp answer"

    assert_transcript(session, emission, "direct", ["WhatsApp question", "WhatsApp answer"])
  end

  test "native group mention produces shared history and a group reply" do
    session = channel_session(:whatsapp, llm_answer: "Group answer")
    emission = emit_message(session, :shared, content: "Group question")
    result = await_exchange(session, emission)
    assert result.reply.channel_id == session.handle.rooms.shared
    assert_transcript(session, emission, "shared", ["Group question", "Group answer"])
  end

  test "the existing wrapper preserves mailbox edits and supports opt-in terminal failures" do
    session = channel_session(:whatsapp)
    room = session.handle.rooms.direct
    opts = [profile: session.handle.opaque.profile]
    assert {:ok, %{external_message_id: id}} = Adapter.send_message(room, "Before", opts)
    assert {:ok, %{external_message_id: ^id}} = Adapter.edit_message(room, id, "After", opts)
    assert Transport.mailbox()[{session.handle.opaque.profile, room, id}] == "After"

    assert :ok =
             session.driver.script(session, %{
               operation: :send,
               match: %{text: "Fail"},
               results: [{:error, :offline}]
             })

    assert {:error, _} = Adapter.send_message(room, "Fail", opts)
    assert Enum.any?(session.driver.deliveries(session), &(&1.outcome == {:error, :offline}))
    refute "Fail" in Map.values(Transport.mailbox())
  end

  test "self messages are suppressed before agent execution" do
    session = channel_session(:whatsapp)
    emission = emit_message(session, :direct, content: "My echo", from_me: true)
    refute Repo.get_by(Zaq.Engine.Conversations.Message, external_message_id: emission.source_id)
    refute_received {:channel_llm_request, _, _}
    assert session.driver.deliveries(session) == []
  end

  test "history callbacks cannot create executions or public messages" do
    session = channel_session(:whatsapp)

    payload = %{
      id: "history-input",
      channel_jid: session.handle.rooms.direct,
      from_jid: session.handle.sender.id,
      to_jid: "15550001@s.whatsapp.net",
      text: "Old history",
      type: :text,
      timestamp: 1_767_323_045,
      metadata: %{history: true},
      account_jids: ["15550001@s.whatsapp.net"]
    }

    assert :ok = JidoChatBridge.from_listener(session.connector, payload, [])
    refute Repo.get_by(Zaq.Engine.Conversations.Message, external_message_id: "history-input")
    refute_received {:channel_llm_request, _, _}
    assert session.driver.deliveries(session) == []
  end

  test "two profiles keep attempts and native recipients separate" do
    first = channel_session(:whatsapp, llm_answer: "First profile")
    second = channel_session(:whatsapp, llm_answer: "Second profile")
    refute first.handle.opaque.profile == second.handle.opaque.profile

    for {session, answer} <- [{first, "First profile"}, {second, "Second profile"}] do
      emission = emit_message(session, :direct, content: "Profile question")
      result = await_exchange(session, emission)
      assert result.reply.body == answer
      assert Enum.all?(result.attempts, &(&1.channel_config_id == session.connector.id))
      assert_transcript(session, emission, "direct", ["Profile question", answer])
    end
  end
end
