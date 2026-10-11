defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Static supervisor and public runtime facade for the Channels role.

  Starts the rate limiter and provider infrastructure before the dynamic bridge
  supervisor. Rest-for-one ordering rebuilds runtimes after shared infrastructure
  failures. Stopping this parent stops all subtrees and releases the ETS table.

  `Zaq.NodeRouter` discovers Channels through this registered name. Registration
  identifies the role, not child readiness. Runtime operations delegate directly
  to the dynamic child, including during its configuration bootstrap.
  """

  use Supervisor

  alias Zaq.Channels.{BridgeSupervisor, LinkedDevice, PeopleAuthRateLimiter}

  @type runtime :: %{listener_pids: [pid()], state_pid: pid() | nil}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children =
      [PeopleAuthRateLimiter] ++ LinkedDevice.infrastructure_children(opts) ++ [{BridgeSupervisor, opts}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts runtime for a config via router bridge delegation."
  @spec start_listener(map()) :: {:ok, runtime()} | {:error, term()}
  defdelegate start_listener(config), to: BridgeSupervisor

  @doc "Stops runtime for a config via router bridge delegation."
  @spec stop_listener(map()) :: :ok | {:error, term()}
  defdelegate stop_listener(config), to: BridgeSupervisor

  @doc "Starts runtime processes for a bridge id; listeners default to an empty list."
  @spec start_runtime(String.t(), map() | nil, list()) :: {:ok, runtime()} | {:error, term()}
  defdelegate start_runtime(bridge_id, state_spec, listener_specs \\ []), to: BridgeSupervisor

  @doc "Stops a bridge runtime by bridge id."
  @spec stop_bridge_runtime(map(), String.t()) :: :ok | {:error, :not_running}
  defdelegate stop_bridge_runtime(config, bridge_id), to: BridgeSupervisor

  @doc "Returns runtime pids for a bridge id, or not_running when absent or stopped."
  @spec lookup_runtime(String.t()) :: {:ok, runtime()} | {:error, :not_running}
  defdelegate lookup_runtime(bridge_id), to: BridgeSupervisor

  @doc "Returns the live state pid for a bridge id."
  @spec lookup_state_pid(String.t()) :: {:ok, pid()} | {:error, :not_running}
  defdelegate lookup_state_pid(bridge_id), to: BridgeSupervisor
end
