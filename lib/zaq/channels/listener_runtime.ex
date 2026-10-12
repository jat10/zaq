defmodule Zaq.Channels.ListenerRuntime do
  @moduledoc """
  Stable supervision handle for an adapter-created ingress listener.

  Abnormal listener exits have a bounded restart budget. Normal/shutdown exits
  stop this handle as well, allowing bridge state to report a stopped listener.
  The adapter owns connection cleanup; this supervisor never adopts connections.
  """
  use Supervisor

  def start_link(spec), do: Supervisor.start_link(__MODULE__, spec)

  @impl true
  def init(spec) do
    child = Map.merge(spec, %{restart: :transient, significant: true})

    Supervisor.init([child],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5,
      auto_shutdown: :any_significant
    )
  end
end
