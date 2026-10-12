defmodule Zaq.Channels.LinkedDevice.Config do
  @moduledoc """
  Pure runtime configuration for connector-scoped linked devices.

  Profiles derive exclusively from persisted connector IDs. The caller supplies
  a credential-bound storage adapter; persisted
  connector settings cannot replace either or choose another account's profile.
  """

  @doc "Returns the stable profile for a persisted connector."
  @spec profile(map()) :: {:ok, String.t()} | {:error, :invalid_connector}
  def profile(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, "zaq_linked_device_#{id}"}

  def profile(_config), do: {:error, :invalid_connector}

  @doc "Builds listener ingress with an explicit, trusted storage binding."
  @spec ingress(map(), {module(), keyword()}) :: {:ok, map()} | {:error, term()}
  def ingress(config, {storage_module, storage_opts} = storage)
      when is_atom(storage_module) and not is_nil(storage_module) and is_list(storage_opts) do
    with {:ok, profile} <- profile(config) do
      {:ok,
       %{
         mode: :linked_device,
         profile: profile,
         config: %{
           profile: profile,
           storage: storage,
           sync_history: false,
           sync_full_history: false
         }
       }}
    end
  end

  def ingress(_config, _storage), do: {:error, :invalid_storage}
end
