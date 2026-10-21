defmodule Zaq.Channels.Integration.Providers.TelegramTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Jido.Chat.Telegram.Adapter
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript}

  test "chat-local message ids remain independent across direct and shared chats" do
    session = channel_session(:telegram, answers: ["Direct answer", "Shared answer"])
    direct = emit_message(session, :direct, content: "Direct input", source_id: "42")
    assert await_exchange(session, direct).reply.body == "Direct answer"
    shared = emit_message(session, :shared, content: "Shared input", source_id: "42")

    assert Repo.get_by(Transcript,
             channel_config_id: session.connector.id,
             external_channel_id: shared.channel_id
           ),
           "Telegram message 42 in a second chat was discarded before creating its scoped transcript"

    assert await_exchange(session, shared).reply.body == "Shared answer"
  end

  test "provider send errors preserve native API payload and failure receipt" do
    session = channel_session(:telegram)

    assert :ok =
             session.driver.script(session, %{
               operation: :send,
               match: %{text: "Fail send"},
               results: [{:error, :offline}]
             })

    assert {:error, _} =
             Adapter.send_message(session.handle.rooms.direct, "Fail send",
               url: session.connector.url,
               token: session.connector.token
             )

    assert [attempt] = session.driver.deliveries(session)
    assert to_string(attempt.native_payload["chat_id"]) == session.handle.rooms.direct
    assert attempt.text == "Fail send"
    assert attempt.outcome == {:error, :offline}
  end

  test "native direct webhook reaches the agent and confirmed direct transcript" do
    session = channel_session(:telegram, llm_answer: "Telegram answer")
    emission = emit_message(session, :direct, content: "Telegram question")
    result = await_exchange(session, emission)
    assert result.reply.body == "Telegram answer"
    assert_transcript(session, emission, "direct", ["Telegram question", "Telegram answer"])
  end

  test "native group mention reaches the agent and confirmed shared transcript" do
    session = channel_session(:telegram, llm_answer: "Group answer")
    emission = emit_message(session, :shared, content: "Group question")
    result = await_exchange(session, emission)
    assert result.reply.channel_id == emission.channel_id
    assert_transcript(session, emission, "shared", ["@zaq Group question", "Group answer"])
  end

  test "mention-required policy admits an actual native group mention" do
    session =
      channel_session(:telegram,
        llm_answer: "Mention answer",
        connector_attrs: %{
          settings: %{
            "jido_chat" => %{
              "bot_name" => "zaq",
              "bot_user_id" => "999",
              "room_reply_policy" => "mention_required"
            }
          }
        }
      )

    emission = emit_message(session, :shared, content: "Mention question")
    # Engine prepares execution before acknowledging ingress; waiting for an LLM
    # cannot repair a message that was admitted only as passive history.
    message =
      Repo.get_by!(Message, source_provider: "telegram", external_message_id: emission.source_id)

    assert Repo.get_by(ExecutionRecord, user_message_id: message.id),
           "Native Telegram @zaq mention was captured without preparing agent execution under mention_required"

    result = await_exchange(session, emission)
    assert result.reply.body == "Mention answer"
  end
end
