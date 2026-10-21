defmodule Zaq.TestSupport.ConnectorCleanupRouter do
  @moduledoc false
  alias Zaq.NodeRouter

  def dispatch(event) do
    NodeRouter.dispatch(event, %{
      whereis_fn: fn _ -> nil end,
      node_list_fn: fn -> [:channels@host] end,
      rpc_call_fn: fn
        _, Process, :whereis, [_] ->
          self()

        _, module, function, [routed | args] ->
          routed = %{
            routed
            | opts: Keyword.put(routed.opts, :cleanup_observer, event.actor.observer)
          }

          event.actor.task_supervisor
          |> Task.Supervisor.async_nolink(fn -> apply(module, function, [routed | args]) end)
          |> Task.await()
      end
    })
  end

  def logout(config, opts) do
    send(
      opts[:cleanup_observer],
      {:cleanup_held, self(), NodeRouter.coordinated?({:connector_lifecycle, config.id})}
    )

    receive do: (:finish_cleanup -> :ok)
  end
end
