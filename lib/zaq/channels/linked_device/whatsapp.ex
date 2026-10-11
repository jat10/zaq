defmodule Zaq.Channels.LinkedDevice.WhatsApp do
  @moduledoc """
  WhatsApp protocol configuration for the shared linked-device integration.

  Historical synchronization is disabled on every connection. Arbitrary Amarula
  options from persisted settings are deliberately not forwarded: they could
  replace storage, identity, transport, or the synchronization policy.
  """

  @behaviour Zaq.Channels.LinkedDevice.Provider

  @impl true
  def connection_config(%{provider: provider}) when provider in ["whatsapp", :whatsapp],
    do: {:ok, %{sync_history: false, sync_full_history: false}}

  def connection_config(_config), do: {:error, :provider_mismatch}
end
