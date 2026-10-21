defmodule Zaq.Channels.Integration.DeliveryFailureTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Zaq.Engine.Conversations
  alias Zaq.TestSupport.Channels.Integration.Registry

  for {provider, _driver} <- Registry.all() do
    @provider provider

    @tag provider: provider, scenario: :failed_send
    test "#{provider}: terminal send failure without a status id remains unconfirmed" do
      session = channel_session(@provider, llm_answer: "Failed send answer")

      assert :ok =
               session.driver.script(session, %{
                 operation: :send,
                 match: %{channel_id: session.handle.rooms.direct},
                 results: List.duplicate({:error, :offline}, 12)
               })

      emission = emit_message(session, :direct, content: "Send failure question")
      result = await_exchange(session, emission)
      assert {:error, _} = result.event.response

      assert Enum.any?(
               result.attempts,
               &(&1.operation == :send and &1.text == "Failed send answer" and
                   &1.outcome == {:error, :offline})
             )

      assert_transcript(session, emission, "direct", ["Send failure question"])
    end

    @tag provider: provider, scenario: :failed_delivery
    test "#{provider}: failed final delivery cannot appear as a confirmed answer" do
      session = channel_session(@provider, llm_answer: "Undelivered answer")
      # A status may already exist, so both terminal operations use an exact text match.
      for operation <- [:send, :edit] do
        assert :ok =
                 session.driver.script(session, %{
                   operation: operation,
                   match: %{text: "Undelivered answer"},
                   results: List.duplicate({:error, :offline}, 8)
                 })
      end

      emission = emit_message(session, :direct, content: "Failure question")
      result = await_exchange(session, emission)
      assert {:error, _} = result.event.response

      assert Enum.any?(
               result.attempts,
               &(&1.text == "Undelivered answer" and &1.outcome == {:error, :offline})
             )

      assert Enum.any?(
               result.attempts,
               &(&1.operation == :edit and &1.text == "Undelivered answer" and
                   &1.outcome == {:error, :offline})
             )

      successful =
        Enum.filter(result.attempts, fn attempt ->
          attempt.operation in [:send, :edit] and match?({:ok, _}, attempt.outcome)
        end)

      assert successful != []
      refute Enum.any?(successful, &(&1.text == "Undelivered answer"))

      transcript = transcript!(session, emission)

      assert {:ok, messages} =
               Conversations.list_canonical_messages(session.person, transcript.id)

      refute Enum.any?(messages, &(&1.content == "Undelivered answer"))
    end

    @tag provider: provider, scenario: :failure_isolation
    test "#{provider}: one connector's script cannot affect another connector" do
      failed = channel_session(@provider, llm_answer: "Scoped answer")

      for operation <- [:send, :edit] do
        :ok =
          failed.driver.script(failed, %{
            operation: operation,
            match: %{text: "Scoped answer"},
            results: List.duplicate({:error, :offline}, 8)
          })
      end

      first = emit_message(failed, :direct, content: "First question")
      assert {:error, _} = await_exchange(failed, first).event.response
      healthy = channel_session(@provider, llm_answer: "Scoped answer")
      second = emit_message(healthy, :direct, content: "Second question")
      result = await_exchange(healthy, second)
      assert {:ok, %{confirmation: :confirmed}} = result.event.response
      assert_transcript(healthy, second, "direct", ["Second question", "Scoped answer"])
      assert Enum.all?(result.attempts, &(&1.channel_config_id == healthy.connector.id))
    end
  end
end
