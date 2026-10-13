defmodule Zaq.Channels.LinkedDevice do
  @moduledoc """
  Host configuration and lifecycle routing for linked-device adapters.

  Adapters own protocol connections and lifecycle normalization. This module
  binds an exact connector to credential storage and routes normalized lifecycle
  notifications separately from message ingress. QR values stay in runtime state.

  Profiles derive exclusively from persisted connector IDs. Trusted runtime
  options supply storage and history policy to adapter child specs; persisted
  settings cannot replace them. The supervisor only starts the supplied specs.
  """
  alias Jido.Chat.WhatsApp.PairingSession
  alias Jido.Chat.WhatsApp.Storage.Split
  alias Zaq.Channels.{Bridge, CommunicationBridge, Supervisor}
  alias Zaq.Channels.JidoChatBridge.{ListenerStatus, State}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @lifecycle_retry_interval 25
  @lifecycle_retries 200

  @doc "Returns the stable profile for a persisted connector."
  @spec profile(map()) :: {:ok, String.t()} | {:error, :invalid_connector}
  def profile(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, "zaq_linked_device_#{id}"}

  def profile(_config), do: {:error, :invalid_connector}

  @doc "Builds adapter ingress options with an explicit, trusted storage binding."
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

  @doc "Enriches linked-device options; all other adapters retain their normal options."
  def listener_opts(config, opts) do
    case Bridge.provider_config(config.provider) do
      %{ingress_mode: :linked_device} -> linked_options(config, opts)
      _ -> {:ok, opts}
    end
  end

  defp linked_options(config, opts) do
    with {:ok, binding} <- bind(config.id),
         {:ok, profile} <- profile(config),
         storage_opts = storage_options(binding, profile),
         :ok <- Split.prepare(Split.new(storage_opts)),
         {:ok, ingress} <- ingress(config, {Split, storage_opts}) do
      {:ok,
       opts
       |> Keyword.put(:ingress, ingress)
       |> Keyword.put(
         :lifecycle_sink_mfa,
         {__MODULE__, :from_lifecycle, [config.provider, config.id]}
       )}
    end
  end

  @doc """
  Relays normalized lifecycle through the confidential Channels boundary.

  The adapter's ordered dispatcher may run before the runtime is registered.
  Retry only that transient response with a bounded startup retry budget,
  retaining the original source PID and event order. Authorization and other
  errors propagate.
  """
  @spec from_lifecycle(atom() | String.t(), pos_integer(), map(), keyword()) ::
          :ok | {:error, term()}
  def from_lifecycle(provider, config_id, payload, _opts) do
    Event.new(
      %{provider: provider, channel_config_id: config_id, source: self(), lifecycle: payload},
      :channels,
      opts: [action: :channel_ingress_lifecycle, confidential: true, channel_runtime: true]
    )
    |> dispatch_lifecycle(@lifecycle_retries)
  end

  defp dispatch_lifecycle(event, retries) do
    case NodeRouter.dispatch(event).response do
      {:error, :runtime_not_ready} when retries > 0 ->
        Process.sleep(@lifecycle_retry_interval)
        dispatch_lifecycle(event, retries - 1)

      response ->
        response
    end
  end

  @doc "Returns the exact bridge's in-memory pairing presentation."
  def status(config) do
    with {:ok, pid} <- Supervisor.lookup_state_pid("#{config.provider}_#{config.id}"),
         %{mode: "linked_device"} = status <- State.ingress_status(pid) do
      {:ok, status}
    else
      _ ->
        {:ok, ListenerStatus.from_lifecycle(%{status: :disconnected, attempt_id: nil, qr: nil})}
    end
  catch
    :exit, _ ->
      {:ok, ListenerStatus.from_lifecycle(%{status: :disconnected, attempt_id: nil, qr: nil})}
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

  @doc "Runs package-owned pairing after the host Action has authorized the operator."
  @spec pair(map(), pos_integer(), map()) :: term()
  def pair(request, user_id, actor) do
    case Bridge.provider_config("whatsapp") do
      %{adapter: adapter} ->
        PairingSession.execute(request, user_id,
          supervisor: Zaq.Channels.BridgeSupervisor,
          attempt_id: Ecto.UUID.generate(),
          adapter: adapter,
          context: actor,
          persist_mfa: {__MODULE__, :confirm_pairing, []},
          start_mfa: {__MODULE__, :start_paired_runtime, []}
        )

      _ ->
        {:error, :pairing_unavailable}
    end
  end

  @doc "Atomically creates the host connector and encrypted durable state."
  @spec confirm_pairing(map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_pairing(actor, request) do
    response =
      request
      |> Event.new(:engine,
        actor: actor,
        opts: [action: :confirm_linked_device, confidential: true, linked_device_runtime: true]
      )
      |> NodeRouter.dispatch()
      |> Map.fetch!(:response)

    with {:ok, config} <- response,
         {:ok, profile} <- profile(config) do
      binding = %{
        channel_config_id: config.id,
        credential_id: config.settings["credential_document_id"]
      }

      {:ok,
       %{
         receipt: %{id: config.id, name: config.name},
         storage: storage_options(binding, profile),
         runtime: config
       }}
    end
  end

  @doc "Starts the saved host bridge after the package has seeded volatile state."
  @spec start_paired_runtime(map(), map()) :: term()
  def start_paired_runtime(_actor, config),
    do: CommunicationBridge.sync_config_runtime(nil, config)
end
