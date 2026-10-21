defmodule Zaq.Channels.Integration.LifecycleTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Zaq.TestSupport.Channels.Integration.{ContractFixture, Driver}

  defmodule FailedConnect do
    @moduledoc false
    @behaviour Driver
    defdelegate start(opts), to: ContractFixture
    def connect(_handle, _context), do: {:error, :synthetic_setup_failure}
    defdelegate emit(session, spec), to: ContractFixture
    defdelegate script(session, script), to: ContractFixture
    defdelegate deliveries(session), to: ContractFixture
    defdelegate capabilities(), to: ContractFixture
  end

  test "configuration and supervised resources are restored after a connect failure" do
    original = snapshot()
    on_exit(fn -> assert snapshot() == original end)
    assert_raise MatchError, fn -> channel_session(:mattermost, driver: FailedConnect) end
  end

  test "sequential providers clean up owned processes and restore exact configuration" do
    original = snapshot()
    on_exit(fn -> assert snapshot() == original end)
    first = channel_session(:mattermost, llm_answer: "First provider answer")
    emission = emit_message(first, :direct, content: "First provider question")
    await_exchange(first, emission)
    second = channel_session(:telegram, llm_answer: "Second provider answer")
    emission = emit_message(second, :direct, content: "Second provider question")
    await_exchange(second, emission)

    assert_transcript(second, emission, "direct", [
      "Second provider question",
      "Second provider answer"
    ])

    on_exit(fn ->
      for pid <- [first.handle.opaque, second.handle.opaque] do
        refute Process.alive?(pid)
      end
    end)
  end

  defp snapshot do
    Map.new(
      [:channels, :node_router, :chat_bridge_pipeline_module],
      &{&1, Application.fetch_env(:zaq, &1)}
    )
  end
end
