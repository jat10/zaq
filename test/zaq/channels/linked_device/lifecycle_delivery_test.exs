defmodule Zaq.Channels.LinkedDevice.LifecycleDeliveryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, BridgeSupervisor, JidoChatBridge}
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Event

  defmodule DelayedListener do
    def start_link(owner) do
      send(owner, {:listener_starting, self()})

      receive do
        :finish_startup -> Agent.start_link(fn -> :listener end)
      end
    end
  end

  test "authorized lifecycle distinguishes readiness from authorization failures" do
    event = event(999_999_999)

    assert Api.handle_event(event, :channel_ingress_lifecycle, nil).response ==
             {:error, :runtime_not_ready}

    for invalid <- [
          %{event | opts: Keyword.delete(event.opts, :confidential)},
          %{event | opts: Keyword.delete(event.opts, :channel_runtime)},
          %{event | request: put_in(event.request, [:lifecycle, :profile], "foreign")},
          %{event | request: %{event.request | provider: "mattermost"}}
        ] do
      assert Api.handle_event(invalid, :channel_ingress_lifecycle, nil).response ==
               {:error, :unauthorized}
    end

    assert {:error, :unauthorized} =
             JidoChatBridge.from_lifecycle("mattermost", 999_999_999, event.request.lifecycle, [])
  end

  test "startup lifecycle waits for registration and preserves source and event order" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"
    config = %{id: id, provider: "whatsapp", settings: %{}, url: "", token: ""}

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
    payload = event(id).request.lifecycle

    dispatcher =
      start_supervised!(
        {Task,
         fn ->
           result = JidoChatBridge.from_lifecycle("whatsapp", id, payload, [])
           send(owner, {:delivered, self(), result})

           receive do
             :connected -> :ok
           end

           result =
             JidoChatBridge.from_lifecycle(
               "whatsapp",
               id,
               %{payload | status: :connected, qr: nil},
               []
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
  test "a runtime that never registers returns the exhausted readiness error" do
    id = 999_999_998

    assert {:error, :runtime_not_ready} =
             JidoChatBridge.from_lifecycle("whatsapp", id, event(id).request.lifecycle, [])
  end

  defp event(id) do
    Event.new(
      %{
        provider: "whatsapp",
        channel_config_id: id,
        source: self(),
        lifecycle: %{
          profile: "zaq_linked_device_#{id}",
          attempt_id: make_ref(),
          status: :pairing,
          qr: "private-qr"
        }
      },
      :channels,
      opts: [action: :channel_ingress_lifecycle, confidential: true, channel_runtime: true]
    )
  end
end
