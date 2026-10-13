defmodule Zaq.Channels.LinkedDevice.RuntimeTest do
  use Zaq.DataCase, async: false
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.LinkedDeviceConnectionStub, as: Transport
  alias Zaq.TestSupport.LinkedDeviceFailingListener

  test "adapter owns correlated lifecycle and expiry without sending control events to chat" do
    {worker, profile} = runtime(qr_timeout: 5)
    assert_receive {:connection, ^profile, _, relay}
    send(relay, {:amarula, :connection_update, %{qr: "private-qr"}})

    assert_receive {:lifecycle,
                    %{profile: ^profile, status: :pairing, qr: "private-qr", attempt_id: attempt}}

    assert_receive {:lifecycle, %{profile: ^profile, status: :expired, qr: nil}}, 1_000
    assert %{status: :expired, qr: nil, attempt_id: ^attempt} = ConnectionWorker.status(worker)
    refute_received {:payload, _, _}
  end

  test "history is suppressed but ordinary queued messages reach the same sink" do
    {_runtime, profile} = runtime()
    assert_receive {:connection, ^profile, _, relay}

    message = %Amarula.Msg{
      id: "queued",
      channel: Amarula.Address.parse("peer@s.whatsapp.net"),
      from: Amarula.Address.parse("peer@s.whatsapp.net"),
      type: :text,
      content: "queued",
      timestamp: 1_700_000_000,
      raw: %{}
    }

    send(relay, {:amarula, :history_sync, %{messages: [%{message | id: "history"}]}})
    send(relay, {:amarula, :messages_upsert, %{messages: [message]}})
    assert_receive {:payload, %{id: "queued", text: "queued"}, _}
    refute_received {:payload, %{id: "history"}, _}
  end

  test "profiles stop independently and duplicate startup cannot steal the existing connection" do
    {_first, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    {_second, second_profile} = runtime()
    assert_receive {:connection, ^second_profile, second_conn, _}

    assert {:error, _} =
             BridgeSupervisor.start_runtime("duplicate_#{profile}", nil, [listener(profile, [])])

    assert Process.alive?(original)
    :ok = BridgeSupervisor.stop_bridge_runtime(%{}, profile)
    refute Process.alive?(original)
    assert Process.alive?(second_conn)
  end

  test "abnormal restart updates the bridge PID and rotates the attempt" do
    {worker, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    %{attempt_id: attempt} = ConnectionWorker.status(worker)
    GenServer.stop(worker, :test_failure)
    assert_receive {:connection, ^profile, replacement, _}, 1_000
    refute original == replacement
    refute Process.alive?(original)
    # Synchronize with completion of the DynamicSupervisor child restart.
    children = DynamicSupervisor.which_children(BridgeSupervisor)

    assert {:ok, %{listener_pids: [replacement_worker]}} =
             BridgeSupervisor.lookup_runtime(profile)

    refute replacement_worker == worker
    assert List.keymember?(children, replacement_worker, 1)
    refute ConnectionWorker.status(replacement_worker).attempt_id == attempt
    assert :ok = BridgeSupervisor.stop_bridge_runtime(%{}, profile)
    refute Process.alive?(replacement_worker)
    refute Process.alive?(replacement)
  end

  test "failed listener startup leaves no runtime" do
    listener = %{id: :failure, start: {LinkedDeviceFailingListener, :start_link, [[]]}}
    assert {:error, _} = BridgeSupervisor.start_runtime("failure", nil, [listener])
  end

  test "a restarted adapter source is monitored and its shutdown clears the QR" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"
    profile = "zaq_linked_device_#{id}"
    config = %{id: id, provider: "whatsapp", settings: %{}, url: "", token: ""}
    state_module = Zaq.Channels.JidoChatBridge.State

    state_spec = %{
      id: :state,
      start:
        {state_module, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    {:ok, listeners} =
      Adapter.listener_child_specs(bridge_id,
        ingress: %{
          mode: :linked_device,
          profile: profile,
          transport: Transport,
          config: %{profile: profile, observer: self()}
        },
        sink_mfa: {Transport, :deliver, [self()]},
        lifecycle_sink_mfa: {Zaq.Channels.JidoChatBridge, :from_lifecycle, ["whatsapp", id]}
      )

    assert {:ok, %{state_pid: state, listener_pids: [worker]}} =
             BridgeSupervisor.start_runtime(bridge_id, state_spec, listeners)

    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id) end)
    assert_receive {:connection, ^profile, _, _relay}
    GenServer.stop(worker, :test_failure)
    assert_receive {:connection, ^profile, _, relay}, 1_000
    DynamicSupervisor.which_children(BridgeSupervisor)
    assert {:ok, %{listener_pids: [replacement]}} = BridgeSupervisor.lookup_runtime(bridge_id)
    refute replacement == worker

    :erlang.trace(state, true, [:receive])
    send(relay, {:amarula, :connection_update, %{qr: "replacement-qr"}})

    assert_receive {:trace, ^state, :receive,
                    {:"$gen_cast", {:lifecycle, source, %{status: :pairing}}}},
                   1_000

    assert %{phase: :pairing, qr: "replacement-qr"} = state_module.ingress_status(state)
    monitor = :sys.get_state(state).lifecycle_monitor
    assert is_reference(monitor)
    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, replacement)
    assert_receive {:trace, ^state, :receive, {:DOWN, ^monitor, :process, ^source, _}}, 1_000
    assert %{phase: :disconnected, qr: nil} = state_module.ingress_status(state)
    :erlang.trace(state, false, [:receive])
  end

  test "shared runtime status preserves pairing presentation and disconnected fallback" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"
    config = %{id: id, provider: "whatsapp", settings: %{}, url: "", token: ""}
    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)

    spec = %{
      id: :state,
      start: {State, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    assert {:ok, %{state_pid: state}} = BridgeSupervisor.start_runtime(bridge_id, spec, [])
    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id) end)
    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)

    GenServer.cast(
      state,
      {:lifecycle, self(),
       %{
         profile: "zaq_linked_device_#{id}",
         attempt_id: make_ref(),
         status: :pairing,
         qr: "private-qr"
       }}
    )

    assert %{phase: :pairing} = State.ingress_status(state)

    assert {:ok, %{mode: "linked_device", phase: :pairing, qr: "private-qr"}} =
             JidoChatBridge.channel_ingress_status(config)

    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, state)
    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)
  end

  defp runtime(opts \\ []) do
    profile = "runtime_#{System.unique_integer([:positive])}"

    assert {:ok, %{listener_pids: [worker]}} =
             BridgeSupervisor.start_runtime(profile, nil, [listener(profile, opts)])

    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, profile) end)
    {worker, profile}
  end

  defp listener(profile, opts) do
    config =
      Map.merge(
        %{profile: profile, observer: self(), sync_history: false, sync_full_history: false},
        Map.new(opts)
      )

    {:ok, [spec]} =
      Adapter.listener_child_specs(profile,
        ingress: %{mode: :linked_device, profile: profile, transport: Transport, config: config},
        sink_mfa: {Transport, :deliver, [self()]},
        lifecycle_sink_mfa: {Transport, :lifecycle, [self()]}
      )

    spec
  end
end
