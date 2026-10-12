defmodule Zaq.Channels.LinkedDevice.RuntimeTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Zaq.Channels.ListenerRuntime
  alias Zaq.TestSupport.LinkedDeviceConnectionStub, as: Transport
  alias Zaq.TestSupport.LinkedDeviceFailingListener

  test "adapter owns correlated lifecycle and expiry without sending control events to chat" do
    {runtime, profile} = runtime(qr_timeout: 5)
    assert_receive {:connection, ^profile, _, relay}
    [{_, worker, _, _}] = Supervisor.which_children(runtime)
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
    {first, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    {_second, second_profile} = runtime()
    assert_receive {:connection, ^second_profile, second_conn, _}

    assert {:error, _} =
             start_supervised(
               Supervisor.child_spec({ListenerRuntime, listener(profile, [])}, id: :duplicate)
             )

    assert Process.alive?(original)
    Supervisor.stop(first)
    refute Process.alive?(original)
    assert Process.alive?(second_conn)
  end

  test "abnormal restart keeps a stable runtime handle and rotates the attempt" do
    {runtime, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    [{_, worker, _, _}] = Supervisor.which_children(runtime)
    %{attempt_id: attempt} = ConnectionWorker.status(worker)
    GenServer.stop(worker, :test_failure)
    assert_receive {:connection, ^profile, replacement, _}, 1_000
    refute original == replacement
    refute Process.alive?(original)
    [{_, worker, _, _}] = Supervisor.which_children(runtime)
    refute ConnectionWorker.status(worker).attempt_id == attempt
  end

  test "failed listener startup leaves no runtime" do
    listener = %{id: :failure, start: {LinkedDeviceFailingListener, :start_link, [[]]}}
    assert {:error, _} = start_supervised({ListenerRuntime, listener})
  end

  defp runtime(opts \\ []) do
    profile = "runtime_#{System.unique_integer([:positive])}"
    spec = Supervisor.child_spec({ListenerRuntime, listener(profile, opts)}, id: profile)
    {start_supervised!(spec), profile}
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
