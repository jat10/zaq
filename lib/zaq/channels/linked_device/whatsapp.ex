defmodule Zaq.Channels.LinkedDevice.WhatsApp do
  @moduledoc """
  WhatsApp protocol configuration for the shared linked-device integration.

  Historical synchronization is disabled on every connection. Arbitrary Amarula
  options from persisted settings are deliberately not forwarded: they could
  replace storage, identity, transport, or the synchronization policy.
  """

  @behaviour Zaq.Channels.LinkedDevice.Provider

  alias Zaq.Channels.LinkedDevice.WhatsAppStorage

  @impl true
  def infrastructure_children, do: [Amarula.Supervisor]

  @doc "Binds Amarula's persistence to the Engine-issued credential association."
  @impl true
  def storage(binding), do: {WhatsAppStorage, binding: binding}

  @doc "Connects or adopts the account after an owner crash without duplicating its session."
  @impl true
  def connect(config, parent) do
    case Amarula.whereis(config.profile) do
      nil ->
        Amarula.new(config) |> Amarula.connect(parent: parent)

      _pid ->
        conn = Amarula.via(config.profile)
        :ok = Amarula.set_parent(conn, parent)
        {:ok, conn}
    end
  end

  @doc "Stops the entire account connection subtree while retaining persisted credentials."
  @impl true
  def stop(config) do
    case Amarula.stop(config.profile) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  @impl true
  def connection_config(%{provider: provider}) when provider in ["whatsapp", :whatsapp],
    do: {:ok, %{sync_history: false, sync_full_history: false}}

  def connection_config(_config), do: {:error, :provider_mismatch}
end
