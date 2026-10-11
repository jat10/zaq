defmodule Zaq.Channels.LinkedDevice.Config do
  @moduledoc """
  Pure runtime configuration for connector-scoped linked devices.

  Profiles derive exclusively from persisted connector IDs. The caller supplies
  a trusted provider module and credential-bound storage adapter; persisted
  connector settings cannot replace either or choose another account's profile.
  """

  @doc "Returns the stable profile for a persisted connector."
  @spec profile(map()) :: {:ok, String.t()} | {:error, :invalid_connector}
  def profile(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, "zaq_linked_device_#{id}"}

  def profile(_config), do: {:error, :invalid_connector}

  @doc "Builds listener ingress with an explicit, trusted storage binding."
  @spec ingress(map(), module(), {module(), keyword()}) :: {:ok, map()} | {:error, term()}
  def ingress(config, provider, {storage_module, storage_opts} = storage)
      when is_atom(storage_module) and not is_nil(storage_module) and is_list(storage_opts) do
    with {:ok, profile} <- profile(config),
         {:ok, protocol_config} <- provider.connection_config(config) do
      {:ok,
       %{
         mode: :linked_device,
         profile: profile,
         config: protocol_config |> Map.put(:profile, profile) |> Map.put(:storage, storage)
       }}
    end
  end

  def ingress(_config, _provider, _storage), do: {:error, :invalid_storage}
end
