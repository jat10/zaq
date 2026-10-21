defmodule Zaq.Channels.Integration.RoundTripTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.TestSupport.Channels.Integration.Registry

  for {provider, _driver} <- Registry.all() do
    @provider provider

    for room <- [:direct, :shared] do
      @room room
      @tag provider: provider, scenario: :round_trip
      test "#{provider}: #{@room} input reaches the LLM and the native recipient" do
        session = channel_session(@provider, llm_answer: "Hello answer")
        emission = emit_message(session, @room, content: "Hello question")
        result = await_exchange(session, emission)
        scope = session.scope
        assert_receive {:channel_llm_request, ^scope, request}
        assert Jason.encode!(request["input"]) =~ "Hello question"
        assert result.reply.body == "Hello answer"
        assert result.reply.channel_id == emission.channel_id
        assert {:ok, %{confirmation: :confirmed, message_id: native_id}} = result.event.response

        assert Enum.any?(
                 result.attempts,
                 &(&1.message_id == native_id and &1.text == "Hello answer")
               )
      end
    end

    @tag provider: provider, scenario: :passive
    test "#{provider}: mention_required captures unmentioned room input without execution" do
      session =
        channel_session(@provider,
          connector_attrs: %{
            settings: %{
              "jido_chat" => %{
                "room_reply_policy" => "mention_required",
                "bot_name" => "zaq",
                "bot_user_id" => "999"
              }
            }
          }
        )

      emission = emit_message(session, :shared, content: "Passive observation", mention?: false)
      message = captured_message!(session, emission)
      assert message.role == "external"
      assert message.conversation_id == nil
      refute Repo.get_by(ExecutionRecord, user_message_id: message.id)
      refute_received {:channel_llm_request, _, _}
      assert session.driver.deliveries(session) == []
    end

    @tag provider: provider, scenario: :two_turns
    test "#{provider}: two sequential turns retain only this permitted exchange" do
      session = channel_session(@provider, answers: ["First answer", "Second answer"])
      first = emit_message(session, :direct, content: "First question")
      await_exchange(session, first)
      scope = session.scope
      assert_receive {:channel_llm_request, ^scope, _first_request}
      second = emit_message(session, :direct, content: "Second question")
      await_exchange(session, second)
      assert_receive {:channel_llm_request, ^scope, request}
      input = Jason.encode!(request["input"])
      for text <- ["First question", "First answer", "Second question"], do: assert(input =~ text)
      refute input =~ "FORBIDDEN"

      assert_transcript(session, second, "direct", [
        "First question",
        "First answer",
        "Second question",
        "Second answer"
      ])
    end

    @tag provider: provider, scenario: :replay
    test "#{provider}: native replay cannot duplicate an execution or answer" do
      session = channel_session(@provider)
      emission = emit_message(session, :direct, content: "Replay question")
      await_exchange(session, emission)
      attempts = session.driver.deliveries(session)
      emit_message(session, :direct, content: "Replay question", source_id: emission.source_id)
      message = captured_message!(session, emission)

      assert [_execution] =
               Repo.all(from e in ExecutionRecord, where: e.user_message_id == ^message.id)

      assert session.driver.deliveries(session) == attempts
      assert_transcript(session, emission, "direct", ["Replay question", "Hello Alice"])
    end
  end

  @tag provider: :mattermost, scenario: :real_tool
  test "a real registered arithmetic tool executes between provider input and final delivery" do
    session =
      channel_session(:mattermost,
        tool_keys: ["arithmetic.add"],
        tool_routes: [
          %{
            match: &String.contains?(&1, "Add numbers"),
            tool: "add",
            arguments: fn _ -> %{value: 2, amount: 3} end
          }
        ],
        llm_final_response: "The sum is 5"
      )

    emission = emit_message(session, :direct, content: "Add numbers")
    result = await_exchange(session, emission)
    assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}
    assert_receive {:llm_tool_result, "add", %{"ok" => true, "result" => %{"result" => 5.0}}}
    assert result.reply.body == "The sum is 5"
    assert_transcript(session, emission, "direct", ["Add numbers", "The sum is 5"])
  end
end
