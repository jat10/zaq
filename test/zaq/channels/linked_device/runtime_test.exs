defmodule Zaq.Channels.LinkedDevice.RuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.LinkedDevice.{ListenerTransport, Owner, Runtime}
  alias Zaq.TestSupport.LinkedDeviceConnectionStub, as: Transport
  alias Zaq.TestSupport.LinkedDeviceFailingListener

  test "pairing status belongs to one owner and restart replaces the attempt" do
    {runtime, profile} = runtime()
    {_other, other_profile} = runtime()
    conn = connection(profile)
    owner = Agent.get(conn, & &1)
    send(owner, {:amarula, :connection_update, %{qr: "private-qr"}})

    assert {:ok, %{qr: "private-qr", phase: :pairing, attempt_id: attempt}} =
             Owner.status(profile)

    assert {:ok, %{qr: nil, phase: :pending}} = Owner.status(other_profile)
    send(owner, {:amarula, :connection_update, %{connection: :open}})
    assert {:ok, %{qr: nil, phase: :connected}} = Owner.status(profile)
    [{_, decoder, _, _}, _] = Supervisor.which_children(runtime)
    ref = Process.monitor(decoder)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^decoder, _}
    await_owner(profile, owner)
    assert {:ok, %{attempt_id: replacement, qr: nil}} = Owner.status(profile)
    refute replacement == attempt
  end

  test "unexpected history batches never reach the decoder, ordinary queued messages do" do
    {_runtime, profile} = runtime()
    owner = Agent.get(connection(profile), & &1)
    send(owner, {:amarula, :history_sync, %{messages: [%{text: "old"}]}})

    send(
      owner,
      {:amarula, :messages_upsert,
       %{
         messages: [
           %Amarula.Msg{
             id: "queued-1",
             channel: Amarula.Address.parse("peer@s.whatsapp.net"),
             from: Amarula.Address.parse("peer@s.whatsapp.net"),
             to: Amarula.Address.parse("self@s.whatsapp.net"),
             type: :text,
             content: "queued",
             timestamp: 1_700_000_000,
             raw: %{}
           }
         ]
       }}
    )

    assert_receive {:payload, %{id: "queued-1", text: "queued"}, _opts}
    refute_receive {:payload, _, _}
  end

  test "failed decoder startup rolls back the connection owner" do
    profile = "failed_#{System.unique_integer([:positive])}"
    listener = %{id: :failed, start: {LinkedDeviceFailingListener, :start_link, [[]]}}

    assert {:error, _reason} =
             start_supervised(
               {Runtime, provider: Transport, config: %{profile: profile}, listener: listener}
             )

    assert connection(profile) == :undefined
    assert :global.whereis_name({Owner, profile}) == :undefined
  end

  test "a second owner cannot take over an active profile" do
    {_runtime, profile} = runtime()
    original = connection(profile)

    assert {:error, _reason} =
             start_supervised(
               Supervisor.child_spec(
                 {Runtime,
                  provider: Transport,
                  config: %{profile: profile},
                  listener: %{
                    id: :unused,
                    start: {LinkedDeviceFailingListener, :start_link, [[]]}
                  }},
                 id: :duplicate
               )
             )

    assert connection(profile) == original
    assert Process.alive?(original)
  end

  test "independent profiles stop separately and preserve decoder forwarding" do
    {first, first_profile} = runtime()
    {_second, second_profile} = runtime()
    first_conn = connection(first_profile)
    second_conn = connection(second_profile)

    send(Agent.get(first_conn, & &1), {:amarula, :pairing_success, %{jid: "first"}})
    assert_receive {:payload, envelope, _opts}
    assert envelope.payload.action_id == "pairing_success"

    Supervisor.stop(first)
    refute Process.alive?(first_conn)
    assert Process.alive?(second_conn)
  end

  test "killed owner adopts existing connection and restarts decoder" do
    {runtime, profile} = runtime()
    conn = connection(profile)
    [{_, decoder, _, _}, {Owner, owner, _, _}] = Supervisor.which_children(runtime)
    ref = Process.monitor(decoder)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^decoder, _}
    new_owner = await_owner(profile, owner)
    assert Process.alive?(conn)
    assert Agent.get(conn, & &1) == new_owner
    send(new_owner, {:amarula, :pairing_success, %{jid: "restored"}})
    assert_receive {:payload, envelope, _opts}, 1_000
    assert envelope.payload.action_id == "pairing_success"
  end

  test "killed decoder reattaches without replacing the connection" do
    {runtime, profile} = runtime()
    conn = connection(profile)
    [{id, decoder, _, _}, _owner] = Supervisor.which_children(runtime)
    :ok = Supervisor.terminate_child(runtime, id)
    assert {:ok, _new_decoder} = Supervisor.restart_child(runtime, id)
    assert connection(profile) == conn
    send(Agent.get(conn, & &1), {:amarula, :pairing_success, %{jid: "same"}})
    assert_receive {:payload, _envelope, _opts}
    refute Process.alive?(decoder)
  end

  defp runtime do
    profile = "test_linked_#{System.unique_integer([:positive])}"
    config = %{profile: profile}

    {:ok, [listener]} =
      Adapter.listener_child_specs(profile,
        ingress: %{mode: :linked_device, profile: profile, transport: ListenerTransport},
        sink_mfa: {Transport, :deliver, [self()]}
      )

    spec =
      Supervisor.child_spec({Runtime, provider: Transport, config: config, listener: listener},
        id: profile
      )

    {start_supervised!(spec), profile}
  end

  defp connection(profile), do: :global.whereis_name({Transport, profile})

  defp await_owner(profile, previous, attempts \\ 100)
  defp await_owner(_profile, _previous, 0), do: flunk("owner did not restart")

  defp await_owner(profile, previous, attempts) do
    case :global.whereis_name({Owner, profile}) do
      pid when is_pid(pid) and pid != previous ->
        _ = :sys.get_state(pid)
        pid

      _ ->
        Process.sleep(5)
        await_owner(profile, previous, attempts - 1)
    end
  end
end
