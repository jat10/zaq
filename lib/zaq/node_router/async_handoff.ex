defmodule Zaq.NodeRouter.AsyncHandoff do
  @moduledoc """
  Transfers coordinated async work without a gap in resource ownership.

  The caller retains its holds until the worker independently acquires every
  scope. The worker waits for a commit before executing; caller death before
  commit cancels execution. A timeout kills and drains the worker before the
  caller releases its holds. A committed worker may outlive its caller.
  """

  alias Zaq.NodeRouter.Coordination

  @doc "Starts a supervised worker and waits for ownership acknowledgement within the scope budget."
  def start(scopes, start_worker, operation) do
    Coordination.run(scopes, fn -> start_held(scopes, start_worker, operation) end)
  end

  defp start_held(scopes, start_worker, operation) do
    parent = self()
    ref = make_ref()

    case start_worker.(fn -> receive_work(parent, ref, scopes, operation) end) do
      {:ok, worker} -> await_ready(worker, ref, Coordination.remaining_timeout(scopes))
      {:error, reason} -> {:error, {:coordination_handoff_failed, reason}}
    end
  end

  defp receive_work(parent, ref, scopes, operation) do
    monitor = Process.monitor(parent)

    try do
      Coordination.run(scopes, fn ->
        send(parent, {ref, :ready})

        receive do
          {^ref, :commit} -> operation.()
          {:DOWN, ^monitor, :process, ^parent, _reason} -> :ok
        end
      end)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_ready(worker, ref, timeout) do
    monitor = Process.monitor(worker)

    receive do
      {^ref, :ready} ->
        send(worker, {ref, :commit})
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, {:coordination_handoff_failed, reason}}
    after
      timeout ->
        Process.exit(worker, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^worker, _reason} -> :ok)
        receive do: ({^ref, :ready} -> :ok), after: (0 -> :ok)
        {:error, :coordination_timeout}
    end
  end
end
