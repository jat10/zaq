defmodule Zaq.Channels.LinkedDevice do
  @moduledoc """
  Shared linked-device integration for JidoChatBridge.

  Resolves credential bindings through Engine, supplies trusted runtime settings,
  and supervises adapter-created listener specs under a connection owner. Provider
  modules own the protocol; this module does not parse QR codes or provider events.
  """

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.LinkedDevice.{Config, ListenerTransport, Runtime}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Returns shared provider infrastructure to start before account runtimes."
  @spec infrastructure_children(keyword()) :: list()
  def infrastructure_children(opts \\ []) do
    Zaq.Config.get(:zaq, :channels, %{}, opts)
    |> Map.values()
    |> Enum.map(&Map.get(&1, :linked_device_provider))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(& &1.infrastructure_children())
    |> Enum.uniq()
  end

  @doc "Builds a supervised account runtime using the registered provider contract."
  @spec listener_specs(map(), String.t(), module(), keyword()) :: {:ok, list()} | {:error, term()}
  def listener_specs(config, bridge_id, adapter, listener_opts) do
    registration = Bridge.provider_config(config.provider)
    provider = registration.linked_device_provider

    with {:ok, binding} <- bind(config.id),
         {:ok, ingress} <- Config.ingress(config, provider, provider.storage(binding)),
         ingress <- Map.put(ingress, :transport, ListenerTransport),
         {:ok, [listener]} <-
           adapter.listener_child_specs(bridge_id, Keyword.put(listener_opts, :ingress, ingress)) do
      spec =
        Supervisor.child_spec(
          {Runtime, provider: provider, config: ingress.config, listener: listener},
          id: {Runtime, bridge_id}
        )

      {:ok, [spec]}
    else
      {:ok, _listeners} -> {:error, :invalid_linked_device_listener_count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :linked_device_storage, confidential: true, linked_device_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
