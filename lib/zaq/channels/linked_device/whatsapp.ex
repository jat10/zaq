defmodule Zaq.Channels.LinkedDevice.WhatsApp do
  @moduledoc """
  WhatsApp protocol configuration for the shared linked-device integration.

  Historical synchronization is disabled on every connection. Arbitrary Amarula
  options from persisted settings are deliberately not forwarded: they could
  replace storage, identity, transport, or the synchronization policy.
  """

  @behaviour Zaq.Channels.LinkedDevice.Provider

  alias Zaq.Channels.LinkedDevice.Config
  alias Zaq.Channels.LinkedDevice.WhatsAppStorage

  @impl true
  def infrastructure_children, do: [Amarula.Supervisor]

  @doc "History imports never enter the message decoder; queued ordinary messages do."
  @impl true
  def forward_event?({:amarula, :history_sync, _}), do: false
  def forward_event?(_), do: true

  @doc "Translates protocol control events without exposing native errors or credentials."
  @impl true
  def pairing_event({:amarula, :connection_update, %{qr: qr}}, state) when is_binary(qr),
    do: {:qr, qr, if(state.qr_count == 0, do: 60_000, else: 20_000)}

  def pairing_event({:amarula, :connection_update, %{connection: :open}}, _), do: :connected

  def pairing_event({:amarula, :connection_update, %{connection: connection}}, _)
      when connection in [:closed, :disconnected], do: :disconnected

  def pairing_event({:amarula, :connection_update, %{connection: :connecting}}, _), do: :pending
  def pairing_event({:amarula, :pairing_success, _}, _), do: :pending
  def pairing_event({:amarula, :pairing_failure, _}, _), do: :failed
  def pairing_event({:amarula, :error, _}, _), do: :failed
  def pairing_event(_, _), do: :ignore

  @doc "Reads the active profile's phone-number and privacy identities for mention matching."
  def own_jids(config) do
    with {:ok, profile} <- Config.profile(config),
         pid when is_pid(pid) <- Amarula.whereis(profile),
         me when is_map(me) <- Map.get(Amarula.Connection.get_auth_creds(pid), :me) do
      me |> Map.take([:id, :lid]) |> Map.values() |> Enum.filter(&is_binary/1)
    else
      _ -> []
    end
  catch
    :exit, _ -> []
  end

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

        send(
          parent,
          {:amarula, :connection_update, %{connection: Amarula.connection_state(conn)}}
        )

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
