defmodule Zaq.TestSupport.LinkedDeviceConnectionStub do
  @moduledoc false

  defdelegate forward_event?(event), to: Zaq.Channels.LinkedDevice.WhatsApp
  defdelegate pairing_event(event, state), to: Zaq.Channels.LinkedDevice.WhatsApp

  def connect(config, parent) do
    name = {:global, {__MODULE__, config.profile}}

    case Agent.start(fn -> parent end, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Agent.update(pid, fn _ -> parent end)
        {:ok, pid}
    end
  end

  def stop(config) do
    case :global.whereis_name({__MODULE__, config.profile}) do
      :undefined -> :ok
      pid -> Agent.stop(pid)
    end
  end

  def deliver(pid, payload, opts) do
    send(pid, {:payload, payload, opts})
    :ok
  end
end
