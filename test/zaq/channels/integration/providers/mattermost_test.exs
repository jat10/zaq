defmodule Zaq.Channels.Integration.Providers.MattermostTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Jido.Chat.Mattermost.Adapter
  alias Zaq.TestSupport.Channels.Integration.{Contract, Registry}

  test "provider errors preserve the actual native request and scoped attempt" do
    session = channel_session(:mattermost)

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

    assert attempt.native_payload == %{
             "channel_id" => session.handle.rooms.direct,
             "message" => "Fail send"
           }

    assert attempt.outcome == {:error, :offline}
    assert attempt.channel_config_id == session.connector.id
  end

  test "an unexpected provider endpoint is visible instead of returning permissive success" do
    session = channel_session(:mattermost)
    response = Req.get!(session.connector.url <> "/unexpected", retry: false)
    assert response.status == 500
    scope = session.scope
    assert_receive {:channel_provider_unexpected, ^scope, {"GET", ["unexpected"]}}
  end

  test "default policy admits a reply to a confirmed bot root without a new mention" do
    session =
      channel_session(:mattermost,
        answers: ["Bot root", "Thread answer"],
        connector_attrs: %{
          settings: %{
            "jido_chat" => %{
              "bot_name" => "zaq",
              "bot_user_id" => "bot",
              "room_reply_policy" => "default"
            }
          }
        }
      )

    root = emit_message(session, :shared, content: "Start a thread")
    completed = await_exchange(session, root)
    {:ok, receipt} = completed.event.response

    reply =
      emit_message(session, :shared,
        content: "Continue here",
        mention?: false,
        thread_id: receipt.message_id
      )

    result = await_exchange(session, reply)
    assert result.reply.body == "Thread answer"
    assert result.reply.thread_id == receipt.message_id
  end

  test "reply to a human root stays captured without an execution unless mentioned" do
    alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
    session = channel_session(:mattermost)
    root = emit_message(session, :shared, content: "Human root", mention?: false)

    reply =
      emit_message(session, :shared,
        content: "Passive reply",
        mention?: false,
        thread_id: root.source_id
      )

    message =
      Repo.get_by!(Message, source_provider: "mattermost", external_message_id: reply.source_id)

    refute Repo.get_by(ExecutionRecord, user_message_id: message.id)
    refute_received {:channel_llm_request, _, _}
    assert session.driver.deliveries(session) == []
  end

  test "native direct message reaches the real agent and confirmed direct history" do
    session = channel_session(:mattermost, llm_answer: "Mattermost answer")
    emission = emit_message(session, :direct, content: "Mattermost question")
    result = await_exchange(session, emission)
    assert result.reply.body == "Mattermost answer"
    assert {:ok, %{confirmation: :confirmed}} = result.event.response
    assert_transcript(session, emission, "direct", ["Mattermost question", "Mattermost answer"])
    assert Enum.any?(result.attempts, &(&1.text == "Mattermost answer"))
    assert Contract.driver!(:mattermost, session.driver).thread_root_lookup
    assert Registry.validate!() == Registry.all()
  end

  test "native channel mention produces shared history through the same runtime" do
    session = channel_session(:mattermost, llm_answer: "Room answer")
    emission = emit_message(session, :shared, content: "Room question")
    result = await_exchange(session, emission)
    assert result.reply.channel_id == emission.channel_id
    assert_transcript(session, emission, "shared", ["@zaq Room question", "Room answer"])
  end
end
