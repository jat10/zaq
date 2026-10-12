defmodule Zaq.Channels.LinkedDevice.LifecycleTest do
  use ExUnit.Case, async: true
  alias Zaq.Channels.JidoChatBridge.State

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
