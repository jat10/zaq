defmodule Zaq.Channels.JidoChatBridge.SessionStorage do
  @moduledoc """
  Connector-scoped credential storage bindings for Jido chat adapter sessions.

  Engine owns credential authorization and encrypted persistence. This module
  supplies a configured adapter with an exact durable credential binding and
  confidential Engine callback. It owns no connections,
  supervision, lifecycle presentation or pairing orchestration.
  """

  alias Jido.Chat.WhatsApp.Storage.Runtime
  alias Zaq.Channels.Bridge
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Supplies the shared package runtime with the host's mandatory RAM-only policy."
  @spec runtime_spec() :: {module(), keyword()}
  def runtime_spec, do: {Runtime, require_ram_schema: true}

  @doc "Returns the stable profile for a persisted connector."
  @spec profile(map()) :: {:ok, String.t()} | {:error, :invalid_connector}
  def profile(%{id: id, provider: provider} = config) when is_integer(id) and id > 0 do
    case Bridge.provider_config(provider) do
      %{adapter: adapter} ->
        with {:ok, options} <- profile_options(config, adapter),
             profile when is_binary(profile) <- options[:profile] do
          {:ok, profile}
        else
          _ -> {:error, :invalid_connector}
        end

      _ ->
        {:error, :invalid_connector}
    end
  end

  def profile(_config), do: {:error, :invalid_connector}

  defp profile_options(%{id: id, settings: settings} = config, adapter) when is_map(settings) do
    credential_id = settings["credential_document_id"] || settings[:credential_document_id]

    if is_integer(credential_id) and connection_options_supported?(adapter) do
      {:ok,
       adapter.connection_options(%{channel_config_id: id, credential_id: credential_id},
         context: :runtime,
         document_mfa: {__MODULE__, :document, []}
       )}
    else
      connection_options(config, adapter)
    end
  end

  defp profile_options(config, adapter), do: connection_options(config, adapter)

  @doc "Asks the configured adapter to reconstruct and prepare saved connection options."
  @spec prepare(map(), module()) :: {:ok, map()} | {:error, term()}
  def prepare(config, adapter) do
    with {:ok, options} <- connection_options(config, adapter),
         {storage_module, storage_opts} when is_atom(storage_module) and is_list(storage_opts) <-
           options[:storage],
         :ok <- storage_module.prepare(storage_module.new(storage_opts)) do
      {:ok,
       Map.merge(options, %{mode: :linked_device, sync_history: false, sync_full_history: false})}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_storage}
    end
  end

  @doc "Resolves the saved binding and delegates protocol option construction to the adapter."
  @spec connection_options(map(), module()) :: {:ok, map()} | {:error, term()}
  def connection_options(%{id: id}, adapter) when is_integer(id) and id > 0 do
    with true <- connection_options_supported?(adapter),
         {:ok, binding} <- bind(id) do
      {:ok,
       adapter.connection_options(binding,
         context: :runtime,
         document_mfa: {__MODULE__, :document, []}
       )}
    else
      false -> {:error, :unsupported}
      {:error, _} = error -> error
    end
  end

  def connection_options(_, _), do: {:error, :invalid_connector}

  defp connection_options_supported?(adapter),
    do: Code.ensure_loaded?(adapter) and function_exported?(adapter, :connection_options, 2)

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
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

  @doc "Handles the shared adapter callback with the same durable binding validation."
  @spec document(term(), map(), map()) :: term()
  def document(_context, binding, request), do: document(binding, request)
end
