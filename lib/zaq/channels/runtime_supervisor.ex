defmodule Zaq.Channels.RuntimeSupervisor do
  @moduledoc """
  Owns configured channel infrastructure and the dynamic bridge supervisor.

  Rest-for-one ordering rebuilds listeners after an infrastructure failure without
  resetting the independent authentication limiter. This supervisor owns the
  runtime registry created by BridgeSupervisor.start_link/1, so bridge restarts
  retain that table while a full runtime subtree restart recreates it.
  """
  use Supervisor

  alias Zaq.Channels.BridgeSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children =
      Zaq.Config.get(:zaq, :channels_runtime_children, [], opts) ++ [{BridgeSupervisor, opts}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
