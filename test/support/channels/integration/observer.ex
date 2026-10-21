defmodule Zaq.TestSupport.Channels.Integration.Observer do
  @moduledoc """
  Observes completion of public channel calls without replacing application code.

  NodeRouter broadcasts before handling an event, and a provider receipt precedes
  Engine confirmation. OTP trace returns from Channels.Api therefore supply the
  actual completion barrier. Separate trace sessions coexist with other tests.
  Only this connector's events are forwarded to its owning test process.
  """
  use GenServer

  @calls [
    {Zaq.Agent.HistorySync, :complete, 3},
    {Zaq.Channels.Api, :handle_event, 3},
    {Zaq.Channels.JidoChatBridge.State, :process_listener_payload, 4},
    {Zaq.Channels.JidoChatBridge.State, :process_webhook_request, 3}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    trace = :trace.session_create(:channel_integration, self(), [])

    for {module, _, _} = mfa <- @calls do
      Code.ensure_loaded!(module)
      :trace.function(trace, mfa, [{:_, [], [{:return_trace}, {:exception_trace}]}], [:local])
    end

    :trace.process(trace, :all, true, [:call])

    {:ok,
     %{
       trace: trace,
       owner: opts[:owner],
       scope: opts[:scope],
       connector: opts[:connector_id],
       pending: %{}
     }}
  end

  @impl true
  def handle_info({:trace, pid, :call, {module, function, args}}, state) do
    case observation(args, state.connector) do
      nil ->
        {:noreply, state}

      observation ->
        key = {pid, {module, function, length(args)}}

        {:noreply,
         %{state | pending: Map.update(state.pending, key, [observation], &[observation | &1])}}
    end
  end

  def handle_info({:trace, pid, kind, mfa, result}, state)
      when kind in [:return_from, :exception_from] do
    key = {pid, mfa}

    case Map.get(state.pending, key, []) do
      [] ->
        {:noreply, state}

      [observation | rest] ->
        send(state.owner, {:channel_integration, state.scope, observation, kind, result})
        {:noreply, %{state | pending: Map.put(state.pending, key, rest)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :trace.session_destroy(state.trace)

  defp observation(
         [
           %Zaq.Event{request: %Zaq.Engine.Messages.Outgoing{routing_context: context}},
           :deliver_outgoing,
           _
         ],
         connector
       ) do
    if Map.get(context, :channel_config_id) == connector, do: :delivery
  end

  defp observation([_pid, %{id: connector}, payload | _], connector), do: {:ingress, payload}

  defp observation([_session, persisted, %Zaq.Engine.Messages.Outgoing{} = outgoing], connector) do
    if Map.get(outgoing.routing_context, :channel_config_id) == connector,
      do: {:runtime_ready, persisted[:user_message_id] || persisted["user_message_id"]}
  end

  defp observation(_, _), do: nil
end
