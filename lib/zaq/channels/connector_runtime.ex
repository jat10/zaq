defmodule Zaq.Channels.ConnectorRuntime do
  @moduledoc "Provider teardown and runtime stages for Engine-resolved connector configurations."

  alias Zaq.Channels.{Bridge, CommunicationBridge}
  alias Zaq.ConnectorConfig.Settings
  alias Zaq.{Event, NodeRouter}

  @doc "Excludes lifecycle cleanup and rechecks saved-binding eligibility before runtime preparation."
  @spec with_start(map() | tuple(), (map() | tuple() -> result)) :: result | {:error, term()}
        when result: term()
  def with_start(%{id: id, provider: provider, kind: kind, settings: settings} = config, fun)
      when is_integer(id) and id > 0 and is_map(settings) do
    if Settings.saved_binding?(config) do
      NodeRouter.with_coordination({:connector_lifecycle, id}, fn ->
        event =
          Event.new(%{channel_config_id: id, provider: provider, kind: kind}, :engine,
            opts: [
              action: :connector_runtime_context,
              confidential: true,
              connector_runtime: true
            ]
          )

        start_current(NodeRouter.dispatch(event).response, config, fun)
      end)
    else
      fun.(config)
    end
  end

  def with_start(config, fun), do: fun.(config)

  defp start_current({:ok, current}, config, fun), do: fun.(Map.merge(config, current))
  defp start_current({:error, _} = error, _config, _fun), do: error
  defp start_current(_, _config, _fun), do: {:error, :connector_unavailable}

  @doc "Tears down ingress using supplied credentials, without configuration persistence."
  def teardown_ingress(%{kind: "data_source"}, _opts), do: {:ok, :not_required}

  def teardown_ingress(%{id: id, provider: provider} = config, opts) do
    case Bridge.provider_config(provider) do
      %{ingress_mode: :webhook} ->
        module = Keyword.get(opts, :communication_bridge_module, CommunicationBridge)

        case module.delete_ingress_subscription(config, %{strict: true, config_id: id}) do
          {:ok, %{deleted: false, reason: reason}} -> {:ok, {:warning, reason}}
          {:ok, _} -> {:ok, :deleted}
          {:error, :unsupported} -> {:ok, :unsupported}
          {:error, reason} -> {:error, {:ingress_teardown_failed, reason}}
          other -> {:error, {:ingress_teardown_failed, {:unexpected_response, other}}}
        end

      _ ->
        {:ok, :not_required}
    end
  end

  def teardown_ingress(_config, _opts), do: {:error, :invalid_request}

  @doc "Reconciles the supplied exact connector runtime without repeating provider teardown."
  def sync_runtime(
        %{id: id, provider: provider, kind: kind} = before_config,
        %{id: id, provider: provider, kind: kind, enabled: true} = after_config,
        opts
      ) do
    if NodeRouter.coordinated?({:connector_lifecycle, id}) do
      sync_enabled_runtime(before_config, after_config, opts)
    else
      {:error, :connector_mismatch}
    end
  end

  def sync_runtime(
        %{id: id, provider: provider, kind: kind},
        %{id: id, provider: provider, kind: kind, enabled: false} = after_config,
        opts
      ) do
    with {:ok, bridge} <- runtime_bridge(provider, kind, opts),
         true <-
           (Code.ensure_loaded?(bridge) and function_exported?(bridge, :stop_runtime, 1)) ||
             {:error, :unsupported} do
      bridge.stop_runtime(after_config)
    end
  end

  def sync_runtime(_before, _after, _opts), do: {:error, :connector_mismatch}

  defp sync_enabled_runtime(%{provider: provider, kind: kind} = before_config, after_config, opts) do
    with {:ok, bridge} <- runtime_bridge(provider, kind, opts),
         true <-
           (Code.ensure_loaded?(bridge) and function_exported?(bridge, :sync_runtime, 2)) ||
             {:error, :unsupported} do
      # Repeated explicit enable retries missing startup without restarting an
      # already-running saved listener. Bridge startup owns that idempotence.
      bridge.sync_runtime(Map.put(before_config, :enabled, false), after_config)
    end
  end

  defp runtime_bridge(provider, kind, opts) do
    key =
      if kind == "data_source",
        do: :data_source_runtime_module,
        else: :communication_runtime_module

    case Keyword.get(opts, key) do
      nil -> Bridge.resolve_bridge(provider)
      module -> {:ok, module}
    end
  end
end
