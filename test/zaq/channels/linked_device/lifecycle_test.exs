defmodule Zaq.Channels.LinkedDevice.LifecycleTest do
  use ExUnit.Case, async: true
  alias Zaq.Channels.JidoChatBridge.State

  test "each replacement lifecycle source is monitored and stale exits cannot disconnect it" do
    config = %{id: 42, provider: "whatsapp", settings: %{}, url: "", token: ""}

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    first = start_supervised!({Agent, fn -> :first end}, id: :first)
    second = start_supervised!({Agent, fn -> :second end}, id: :second)

    payload = %{
      profile: "zaq_linked_device_42",
      attempt_id: make_ref(),
      status: :pairing,
      qr: "private"
    }

    GenServer.cast(pid, {:lifecycle, first, payload})
    assert %{phase: :pairing} = State.ingress_status(pid)
    first_ref = :sys.get_state(pid).lifecycle_monitor
    assert is_reference(first_ref)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert {:process, first} in monitors

    :erlang.trace(pid, true, [:receive])
    stop_supervised(:first)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^first_ref, :process, ^first, _}}
    assert %{phase: :disconnected, qr: nil} = State.ingress_status(pid)

    replacement = %{payload | attempt_id: make_ref(), status: :connected, qr: nil}
    GenServer.cast(pid, {:lifecycle, second, replacement})
    assert %{phase: :connected} = State.ingress_status(pid)
    second_ref = :sys.get_state(pid).lifecycle_monitor
    refute second_ref == first_ref

    send(pid, {:DOWN, first_ref, :process, first, :killed})
    assert %{phase: :connected} = State.ingress_status(pid)

    stop_supervised(:second)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^second_ref, :process, ^second, _}}
    assert %{phase: :disconnected, qr: nil} = State.ingress_status(pid)
    :erlang.trace(pid, false, [:receive])
  end

  test "listener exits cannot overwrite the current lifecycle source status" do
    config = %{id: 42, provider: "whatsapp", settings: %{}, url: "", token: ""}

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    listener = start_supervised!({Agent, fn -> :listener end})
    State.monitor_listeners(pid, [listener])

    payload = %{
      profile: "zaq_linked_device_42",
      attempt_id: make_ref(),
      status: :connected,
      qr: nil
    }

    GenServer.cast(pid, {:lifecycle, self(), payload})
    assert %{phase: :connected} = State.ingress_status(pid)
    [{ref, ^listener}] = Map.to_list(:sys.get_state(pid).listener_monitors)
    :erlang.trace(pid, true, [:receive])
    stop_supervised(Agent)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^ref, :process, ^listener, _}}
    assert %{phase: :connected} = State.ingress_status(pid)
    :erlang.trace(pid, false, [:receive])
  end

  test "a replacement event ahead of a queued old DOWN retains its status" do
    config = %{id: 42, provider: "whatsapp", settings: %{}, url: "", token: ""}

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    first = start_supervised!({Agent, fn -> :first end}, id: :first)
    second = start_supervised!({Agent, fn -> :second end}, id: :second)

    payload = %{
      profile: "zaq_linked_device_42",
      attempt_id: make_ref(),
      status: :connected,
      qr: nil
    }

    GenServer.cast(pid, {:lifecycle, first, payload})
    assert %{phase: :connected} = State.ingress_status(pid)
    old_ref = :sys.get_state(pid).lifecycle_monitor

    replacement = %{payload | attempt_id: make_ref()}
    GenServer.cast(pid, {:lifecycle, second, replacement})
    assert :sys.get_state(pid).lifecycle_source == first

    :sys.suspend(pid)

    try do
      GenServer.cast(pid, {:lifecycle, second, replacement})
      stop_supervised(:first)
    after
      :sys.resume(pid)
    end

    assert :sys.get_state(pid).lifecycle_source == second
    send(pid, {:DOWN, old_ref, :process, first, :shutdown})
    assert %{phase: :connected} = State.ingress_status(pid)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert {:process, second} in monitors
    refute {:process, first} in monitors
  end

  test "lifecycle is profile and attempt scoped, survives config refresh and clears expired QR" do
    config = %{id: 42, provider: "whatsapp", settings: %{}, url: "", token: ""}

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    attempt = make_ref()

    event = %{
      profile: "zaq_linked_device_42",
      attempt_id: attempt,
      event: :qr,
      status: :pairing,
      qr: "private"
    }

    GenServer.cast(pid, {:lifecycle, self(), event})
    assert %{phase: :pairing, qr: "private"} = State.ingress_status(pid)
    assert :ok = State.refresh_config(pid, config)
    assert %{phase: :pairing, qr: "private"} = State.ingress_status(pid)
    GenServer.cast(pid, {:lifecycle, self(), %{event | attempt_id: make_ref(), qr: "stale"}})

    GenServer.cast(
      pid,
      {:lifecycle, self(), %{event | profile: "zaq_linked_device_99", qr: "foreign"}}
    )

    assert %{qr: "private"} = State.ingress_status(pid)
    GenServer.cast(pid, {:lifecycle, self(), %{event | status: :expired, qr: nil}})
    assert %{phase: :expired, qr: nil} = State.ingress_status(pid)
    GenServer.cast(pid, {:lifecycle, self(), %{event | status: :connected, qr: nil}})
    assert %{phase: :connected, qr: nil} = State.ingress_status(pid)
    refute inspect(:sys.get_status(pid)) =~ "private"
  end
end
