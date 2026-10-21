defmodule Zaq.TestSupport.Channels.Integration.ContractFixture do
  @moduledoc "A test-only provider double for exercising the harness contract itself."
  @behaviour Zaq.TestSupport.Channels.Integration.Driver

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @impl true
  def start(opts) do
    state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{script: nil, deliveries: []} end},
          id: {__MODULE__, opts[:scope]}
        )
      )

    {:ok,
     %{
       provider: Keyword.get(opts, :provider, :fixture),
       adapter: __MODULE__,
       ingress_mode: :webhook,
       connector_attrs: %{url: "http://127.0.0.1:1", token: "fixture-token"},
       sender: %{id: "sender-#{opts[:scope]}"},
       rooms: %{direct: "dm", shared: "room"},
       opaque: state,
       scope: opts[:scope]
     }}
  end

  @impl true
  def connect(handle, _context), do: {:ok, handle}

  @impl true
  def emit(session, message) do
    Agent.get_and_update(session.handle.opaque, fn state ->
      {outcome, remaining} = consume_script(state.script, message)

      attempt = %{
        sequence: length(state.deliveries) + 1,
        operation: :send,
        provider: :fixture,
        channel_config_id: session.connector.id,
        channel_id: "dm",
        thread_id: nil,
        message_id: nil,
        text: message.content,
        outcome: outcome,
        native_payload: message
      }

      {outcome, %{state | deliveries: state.deliveries ++ [attempt], script: remaining}}
    end)
  end

  @impl true
  def script(session, script) do
    Agent.update(session.handle.opaque, &%{&1 | script: script})
  end

  @impl true
  def deliveries(session), do: Agent.get(session.handle.opaque, & &1.deliveries)

  @impl true
  def capabilities do
    %{
      direct: true,
      shared: true,
      threads: {:unsupported, "Fixture has no native threads"},
      thread_root_lookup: {:unsupported, "Fixture has no root lookup"},
      edits: true
    }
  end

  defp consume_script(
         %{operation: :send, match: match, results: [result | rest]} = script,
         message
       ) do
    if Map.take(message, Map.keys(match)) == match,
      do: {result, %{script | results: rest}},
      else: {{:error, :unstubbed}, script}
  end

  defp consume_script(script, _message), do: {{:error, :unstubbed}, script}
end
