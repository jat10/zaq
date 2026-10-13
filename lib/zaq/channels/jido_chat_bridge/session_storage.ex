defmodule Zaq.Channels.JidoChatBridge.SessionStorage do
  @moduledoc """
  Connector-scoped credential storage bindings for Jido chat adapter sessions.

  Engine owns credential authorization and encrypted persistence. This module
  supplies the WhatsApp package's split backend with a stable profile, exact
  credential scope and confidential Engine callback. It owns no connections,
  supervision, lifecycle presentation or pairing orchestration.
  """

  alias Jido.Chat.WhatsApp.Storage.{Runtime, Split}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Supplies the shared package runtime with the host's mandatory RAM-only policy."
  @spec runtime_spec() :: {module(), keyword()}
  def runtime_spec, do: {Runtime, require_ram_schema: true}

  @doc "Returns the stable profile for a persisted connector."
  @spec profile(map()) :: {:ok, String.t()} | {:error, :invalid_connector}
  def profile(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, "zaq_linked_device_#{id}"}

  def profile(_config), do: {:error, :invalid_connector}

  @doc "Binds and prepares the adapter backend for an exact saved connector."
  @spec prepare(map()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def prepare(config) do
    with {:ok, profile} <- profile(config),
         {:ok, binding} <- bind(config.id),
         opts = storage_options(binding, profile),
         :ok <- Split.prepare(Split.new(opts)) do
      {:ok, {Split, opts}}
    end
  end

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  @doc "Supplies trusted host policy to the package's composite backend."
  @spec storage_options(map(), String.t()) :: keyword()
  def storage_options(binding, profile) do
    [
      context: binding,
      profile: profile,
      scope: {binding.channel_config_id, binding.credential_id},
      document_mfa: {__MODULE__, :document, []},
      volatile_namespaces: ["session", "sender_key"]
    ]
  end

  @doc "Dispatches package storage callbacks through canonical Engine authorization."
  @spec document(map(), map()) :: term()
  def document(binding, request) do
    request
    |> Map.put(:binding, binding)
    |> Event.new(:engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch(%{
      rpc_call_with_timeout_fn: fn node, module, function, args, _ ->
        :rpc.call(node, module, function, args, 6_000)
      end
    })
    |> Map.fetch!(:response)
  end
end
