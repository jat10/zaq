defmodule Zaq.TestSupport.LinkedDeviceProviderStub do
  @moduledoc false
  @behaviour Zaq.Channels.LinkedDevice.Provider

  @impl true
  def connection_config(_config), do: {:ok, %{pairing_method: :code}}
end
