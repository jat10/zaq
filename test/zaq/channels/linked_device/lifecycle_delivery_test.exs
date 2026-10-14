defmodule Zaq.Channels.LinkedDevice.LifecycleDeliveryTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.{BridgeSupervisor, JidoChatBridge}
  alias Zaq.Channels.JidoChatBridge.SessionStorage
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.LinkedDeviceLifecycle

  defmodule DelayedListener do
    def start_link(owner) do
      send(owner, {:listener_starting, self()})

      receive do
        :finish_startup -> Agent.start_link(fn -> :listener end)
      end
    end
  end

  test "startup lifecycle waits for registration and preserves source and event order" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"

    config = %{
      id: id,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

    state_spec = %{
      id: :state,
      start: {State, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    listener_spec = %{id: :listener, start: {DelayedListener, :start_link, [self()]}}

    startup =
      Task.async(fn -> BridgeSupervisor.start_runtime(bridge_id, state_spec, [listener_spec]) end)

    assert_receive {:listener_starting, supervisor}

    on_exit(fn ->
      BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id)
    end)

    owner = self()

    payload = %{
      profile:
        Adapter.connection_options(%{channel_config_id: id, credential_id: 1},
          context: :runtime,
          document_mfa: {SessionStorage, :document, []}
        ).profile,
      attempt_id: make_ref(),
      status: :pairing,
      qr: "private-qr"
    }

    dispatcher =
      start_supervised!(
        {Task,
         fn ->
           result =
             JidoChatBridge.from_listener(config, LinkedDeviceLifecycle.envelope(self(), payload),
               bridge_id: bridge_id
             )

           send(owner, {:delivered, self(), result})

           receive do
             :connected -> :ok
           end

           result =
             JidoChatBridge.from_listener(
               config,
               LinkedDeviceLifecycle.envelope(self(), %{payload | status: :connected, qr: nil}),
               bridge_id: bridge_id
             )

           send(owner, {:connected, result})

           receive do
             :stop -> :ok
           end
         end}
      )

    # Delivery must remain pending while the real listener startup holds the
    # supervisor before runtime publication; this is a bounded negative assertion.
    try do
      refute_receive {:delivered, ^dispatcher, _}, 50
    after
      send(supervisor, :finish_startup)
    end

    assert {:ok, %{state_pid: state}} = Task.await(startup)
    assert_receive {:delivered, ^dispatcher, :ok}, 1_000
    assert %{phase: :pairing, qr: "private-qr"} = State.ingress_status(state)
    assert :sys.get_state(state).lifecycle_source == dispatcher
    send(dispatcher, :connected)
    assert_receive {:connected, :ok}
    assert %{phase: :connected, qr: nil} = State.ingress_status(state)
  end

  @tag timeout: 10_000
  test "a runtime that never registers returns a terminal readiness error" do
    config = %{id: 999_999_998, provider: "whatsapp", settings: %{}}

    assert {:error, :runtime_unavailable} =
             JidoChatBridge.from_listener(config, %{}, bridge_id: "whatsapp_999999998")
  end
end
