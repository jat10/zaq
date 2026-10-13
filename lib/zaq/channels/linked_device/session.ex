defmodule Zaq.Channels.LinkedDevice.Session do
  @moduledoc """
  Owns a temporary WhatsApp connection until operator confirmation.

  Messages are discarded. Protocol state stays in a separate volatile process so
  stopping the worker can finish its writes before durable records are transferred
  to Engine and messaging records are seeded into RAM-only Mnesia. A bounded
  lifetime and browser monitor clean up abandoned pairings.
  Confirmation retains a receipt for repeat clicks; only the normal bridge handles
  messages after persistence. Handles are owner-scoped, including across nodes.
  """
  use GenServer, restart: :temporary
  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Channels.{Bridge, CommunicationBridge, LinkedDevice}
  alias Zaq.Channels.JidoChatBridge.ListenerStatus
  alias Zaq.Channels.LinkedDevice.{Storage, TemporaryStorage}
  alias Zaq.{Event, NodeRouter}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def execute(%{op: :begin, owner: owner}, user_id, actor) when is_pid(owner) do
    case DynamicSupervisor.start_child(
           Zaq.Channels.BridgeSupervisor,
           {__MODULE__, [owner: owner, user_id: user_id, actor: actor]}
         ) do
      {:ok, pid} -> {:ok, %{session: pid, phase: :pending, summary: "Preparing QR code"}}
      _ -> {:error, :pairing_unavailable}
    end
  end

  def execute(%{op: op, session: pid}, user_id, _actor)
      when is_pid(pid) and op in [:status, :retry, :cancel, :confirm] do
    GenServer.call(pid, {user_id, op}, 30_000)
  catch
    :exit, _ -> {:error, :pairing_expired}
  end

  def execute(_, _, _), do: {:error, :invalid_request}

  @doc "Provisional devices cannot enter the agent message path."
  def discard_message(_payload, _opts), do: :ok

  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Ecto.UUID.generate()
    profile = "zaq_pairing_#{id}"
    {:ok, storage} = TemporaryStorage.start_link(profile)
    Process.monitor(Keyword.fetch!(opts, :owner))
    Process.send_after(self(), :expire, 180_000)

    state = %{
      id: id,
      profile: profile,
      storage: storage,
      user_id: opts[:user_id],
      actor: opts[:actor],
      runtime: nil,
      worker: nil,
      snapshot: nil,
      identity: nil,
      saved: nil,
      presented: nil
    }

    case connect(state) do
      {:ok, state} ->
        {:ok, state}

      _ ->
        GenServer.stop(storage)
        {:stop, :pairing_unavailable}
    end
  end

  def handle_call({id, _}, _, %{user_id: owner} = state) when id != owner,
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call({_, :status}, _, state) do
    status = presentation(state)
    presented = confirmation_key(status)
    {:reply, {:ok, status}, %{state | presented: presented}}
  end

  def handle_call({_, :cancel}, _, state), do: {:stop, :normal, :ok, state}

  def handle_call({_, :confirm}, _, %{saved: saved} = state) when not is_nil(saved),
    do: {:reply, {:ok, %{saved: saved, phase: :saved}}, state}

  def handle_call({_, :confirm}, _, state) do
    case freeze(state) do
      {:ok, frozen} -> persist(frozen)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({_, :retry}, _, %{snapshot: snapshot} = state) when not is_nil(snapshot),
    do: {:reply, {:ok, presentation(state)}, state}

  def handle_call({_, :retry}, _, state) do
    result = ConnectionWorker.reconnect(state.worker)
    {:reply, if(result == :ok, do: {:ok, presentation(state)}, else: result), state}
  end

  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _, _}, state), do: {:stop, :normal, state}

  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)

  def terminate(_, state) do
    if is_pid(state.worker) and Process.alive?(state.worker),
      do: safely(fn -> ConnectionWorker.logout(state.worker) end)

    if is_pid(state.runtime) and Process.alive?(state.runtime),
      do: safely(fn -> Supervisor.stop(state.runtime) end)

    if Process.alive?(state.storage), do: safely(fn -> GenServer.stop(state.storage) end)
    :ok
  end

  defp connect(state) do
    provider = Bridge.provider_config("whatsapp")

    ingress = %{
      mode: :linked_device,
      profile: state.profile,
      config: %{
        profile: state.profile,
        storage: {TemporaryStorage, pid: state.storage},
        sync_history: false,
        sync_full_history: false
      }
    }

    with %{adapter: adapter} <- provider,
         {:ok, [spec]} <-
           adapter.listener_child_specs(state.profile,
             ingress: ingress,
             sink_mfa: {__MODULE__, :discard_message, []}
           ),
         {:ok, runtime} <- Supervisor.start_link([spec], strategy: :one_for_one),
         [{_, worker, _, _}] <- Supervisor.which_children(runtime) do
      {:ok, %{state | runtime: runtime, worker: worker}}
    end
  end

  defp presentation(%{saved: saved}) when not is_nil(saved), do: %{phase: :saved, saved: saved}

  defp presentation(%{snapshot: snapshot, identity: identity}) when not is_nil(snapshot),
    do: %{phase: :confirm, identity: identity, summary: "Confirm this WhatsApp account"}

  defp presentation(state) do
    status = ConnectionWorker.status(state.worker)
    projected = ListenerStatus.from_lifecycle(status)

    case status do
      %{status: :connected, identity: %{phone_number: phone} = identity} when is_binary(phone) ->
        Map.merge(projected, %{
          phase: :confirm,
          identity: identity,
          summary: "Confirm this WhatsApp account"
        })

      %{status: :connected, identity_status: :pending} ->
        Map.merge(projected, %{phase: :pending, summary: "Reading account details"})

      %{status: :connected} ->
        Map.merge(projected, %{
          phase: :failed,
          summary: "Account phone number unavailable; retry connection"
        })

      _ ->
        projected
    end
  end

  defp freeze(%{snapshot: snapshot} = state) when not is_nil(snapshot), do: {:ok, state}

  defp freeze(state) do
    case presentation(state) do
      %{phase: :confirm} = status ->
        if confirmation_key(status) == state.presented do
          freeze_confirmed(state, status.identity)
        else
          {:error, :identity_changed}
        end

      _ ->
        {:error, :identity_not_ready}
    end
  end

  defp confirmation_key(%{
         phase: :confirm,
         attempt_id: attempt,
         identity: %{phone_number: phone}
       }),
       do: {attempt, phone}

  defp confirmation_key(_), do: nil

  defp freeze_confirmed(state, identity) do
    Process.unlink(state.runtime)
    :ok = Supervisor.stop(state.runtime)

    {:ok,
     %{
       state
       | runtime: nil,
         worker: nil,
         snapshot: TemporaryStorage.freeze(state.storage),
         identity: identity
     }}
  end

  defp persist(state) do
    request = %{
      attempt_id: state.id,
      identity: state.identity,
      records: Storage.durable_records(state.snapshot)
    }

    response =
      Event.new(request, :engine,
        actor: state.actor,
        opts: [action: :confirm_linked_device, confidential: true, linked_device_runtime: true]
      )
      |> NodeRouter.dispatch()
      |> Map.fetch!(:response)

    case response do
      {:ok, config} ->
        # Persistence succeeded even when the runtime cannot start yet.
        result = start_saved_runtime(config, state.snapshot)
        :ok = TemporaryStorage.discard(state.storage)
        saved = %{id: config.id, name: config.name, runtime_pending: result != :ok}
        {:reply, {:ok, %{phase: :saved, saved: saved}}, %{state | saved: saved, snapshot: nil}}

      _ ->
        {:reply, {:error, :save_failed}, state}
    end
  end

  defp start_saved_runtime(config, snapshot) do
    binding = %{
      channel_config_id: config.id,
      credential_id: config.settings["credential_document_id"]
    }

    with {:ok, profile} <- LinkedDevice.profile(config),
         :ok <- Storage.seed(Storage.new(binding: binding, profile: profile), snapshot),
         do: CommunicationBridge.sync_config_runtime(nil, config)
  rescue
    _ -> {:error, :runtime_unavailable}
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  defp safely(fun) do
    fun.()
  catch
    _, _ -> :ok
  end
end
