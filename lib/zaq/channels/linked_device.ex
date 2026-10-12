defmodule Zaq.Channels.LinkedDevice do
  @moduledoc """
  Host configuration and lifecycle routing for linked-device adapters.

  Adapters own protocol connections and lifecycle normalization. This module
  binds an exact connector to credential storage and routes normalized lifecycle
  notifications separately from message ingress. QR values stay in runtime state.
  """
  alias Zaq.Channels.{Bridge, Supervisor}
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Channels.LinkedDevice.{Config, Pairing, Storage}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Enriches linked-device options; all other adapters retain their normal options."
  def listener_opts(config, opts) do
    case Bridge.provider_config(config.provider) do
      %{ingress_mode: :linked_device} -> linked_options(config, opts)
      _ -> {:ok, opts}
    end
  end

  defp linked_options(config, opts) do
    with {:ok, binding} <- bind(config.id),
         {:ok, profile} <- Config.profile(config),
         {:ok, ingress} <- Config.ingress(config, {Storage, binding: binding, profile: profile}) do
      {:ok,
       opts
       |> Keyword.put(:ingress, ingress)
       |> Keyword.put(
         :lifecycle_sink_mfa,
         {__MODULE__, :from_lifecycle, [config.provider, config.id]}
       )}
    end
  end

  @doc "Relays normalized lifecycle through the confidential Channels boundary."
  def from_lifecycle(provider, config_id, payload, _opts) do
    Event.new(
      %{provider: provider, channel_config_id: config_id, source: self(), lifecycle: payload},
      :channels,
      opts: [action: :channel_ingress_lifecycle, confidential: true, channel_runtime: true]
    )
    |> NodeRouter.dispatch()

    :ok
  end

  @doc "Returns the exact bridge's in-memory pairing presentation."
  def status(config) do
    with {:ok, pid} <- Supervisor.lookup_state_pid("#{config.provider}_#{config.id}"),
         %{mode: "linked_device"} = status <- State.ingress_status(pid) do
      {:ok, status}
    else
      _ -> {:ok, Pairing.from_notification(%{status: :disconnected, attempt_id: nil, qr: nil})}
    end
  catch
    :exit, _ ->
      {:ok, Pairing.from_notification(%{status: :disconnected, attempt_id: nil, qr: nil})}
  end

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
