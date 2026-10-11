defmodule Zaq.Channels.LinkedDevice.Runtime do
  @moduledoc """
  Supervision boundary for an account connection owner and adapter-created decoder.

  Owner restart replaces the decoder; decoder restart reattaches to the same owner.
  The outer supervisor PID stays stable for the existing bridge runtime registry.
  """
  use Supervisor

  alias Zaq.Channels.LinkedDevice.Owner

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    listener = opts |> Keyword.fetch!(:listener) |> Map.put(:restart, :permanent)
    owner = {Owner, Keyword.take(opts, [:provider, :config])}
    Supervisor.init([owner, listener], strategy: :rest_for_one)
  end
end
