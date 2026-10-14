defmodule Zaq.Channels.LinkedDevice.OnboardingTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.SessionStorage
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.{Event, NodeRouter}
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  setup do
    previous = Application.fetch_env!(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    start_supervised!({Transport, observer: self()})
    %{actor: %{user_id: super_admin_fixture(%{must_change_password: false}).id}}
  end

  test "scan creates no connector; confirmation saves and restores the session once", %{
    actor: actor
  } do
    count = Repo.aggregate(ChannelConfig, :count)
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)

    assert Enum.any?(DynamicSupervisor.which_children(Zaq.Channels.BridgeSupervisor), fn
             {_, ^session, :worker, _} -> true
             _ -> false
           end)

    on_exit(fn -> call(%{op: :cancel, session: session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:error, :identity_not_ready} =
             call(%{op: :confirm, session: session, account_id: "+15550001"}, actor)

    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    temporary_scope = Amarula.Storage.scope(options.storage)

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :session, "peer", "ratchet")

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :sender_key, "group", "key")

    assert await_phase(session, actor, :authenticated)
    account_id = account_id(session, actor)
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:ok, %{receipt: saved, runtime_pending: false}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert saved.name == "Support account"
    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)

    assert {:ok, %{receipt: ^saved, runtime_pending: false}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert Repo.aggregate(ChannelConfig, :count) == count + 1
    assert_receive {:whatsapp_connected_config, restored}
    refute restored.sync_history
    refute restored.sync_full_history
    assert {:ok, restored.profile} == SessionStorage.profile(config)
    restored_scope = Amarula.Storage.scope(restored.storage)

    assert {:ok, "ratchet"} =
             Amarula.Storage.get(restored_scope, restored.profile, :session, "peer")

    assert {:ok, "key"} =
             Amarula.Storage.get(restored_scope, restored.profile, :sender_key, "group")

    binding = %{
      channel_config_id: config.id,
      credential_id: config.settings["credential_document_id"]
    }

    for namespace <- ["session", "sender_key"] do
      assert {:ok, []} =
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: namespace
               })
    end

    assert {:ok, conn} = Transport.resolve_conn(profile: restored.profile)
    assert Agent.get(conn, & &1.paired?)
    assert config.settings["account"]["external_id"] == "+15550001"
  end

  test "confirmation rejects an account changed since it was displayed", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    :ok = Transport.scan(options.profile, qr)
    assert await_phase(session, actor, :authenticated)
    displayed_account_id = account_id(session, actor)
    {:ok, conn} = Transport.resolve_conn(profile: options.profile)

    Agent.update(
      conn,
      &Map.put(&1, :identity, %{
        phone_number: "+15550002",
        display_name: nil,
        account_jids: ["15550002@s.whatsapp.net"]
      })
    )

    worker = :sys.get_state(session).worker
    :ok = ConnectionWorker.refresh_identity(worker)
    assert identity_ready?(worker)

    assert {:error, :identity_changed} =
             call(%{op: :confirm, session: session, account_id: displayed_account_id}, actor)

    assert {:ok, %{phase: :cancelled}} = call(%{op: :cancel, session: session}, actor)
  end

  test "a RAM seed failure retains saved pairing and reports connection pending", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    on_exit(fn -> call(%{op: :cancel, session: session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    assert await_phase(session, actor, :authenticated)
    account_id = account_id(session, actor)

    # Fits provisional storage but exceeds the encoded per-record RAM limit.
    assert :ok =
             Amarula.Storage.put(
               Amarula.Storage.scope(options.storage),
               options.profile,
               :session,
               "peer",
               String.duplicate("s", 1024 * 1024)
             )

    assert {:ok, %{receipt: saved, runtime_pending: true}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert {:ok, %{receipt: ^saved, runtime_pending: true}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    refute_received {:whatsapp_connected_config, _}

    assert :ok = JidoChatBridge.start_runtime(config)
    assert_receive {:whatsapp_connected_config, restored}
    scope = Amarula.Storage.scope(restored.storage)
    assert {:ok, %{paired: true}} = Amarula.Storage.get(scope, restored.profile, :creds, :self)
    assert :error = Amarula.Storage.get(scope, restored.profile, :session, "peer")
  end

  defp identity_ready?(worker, attempts \\ 100)
  defp identity_ready?(_, 0), do: false

  defp identity_ready?(worker, attempts) do
    case ConnectionWorker.status(worker) do
      %{identity: %{phone_number: "+15550002"}} ->
        true

      _ ->
        Process.sleep(10)
        identity_ready?(worker, attempts - 1)
    end
  end

  test "owner scoping and cancellation remove provisional sessions", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    assert_receive {:whatsapp_connected_config, options}
    other = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
    assert {:error, :unauthorized} = call(%{op: :status, session: session}, other)
    assert {:ok, %{phase: :cancelled}} = call(%{op: :cancel, session: session}, actor)
    refute Process.alive?(session)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: options.profile)
  end

  test "expiry and browser disconnect clean up without creating a connector", %{actor: actor} do
    count = Repo.aggregate(ChannelConfig, :count)

    for reason <- [:expiry, :browser] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, %{session: session}} = call(%{op: :begin, owner: owner}, actor)
      assert_receive {:whatsapp_connected_config, options}
      monitor = Process.monitor(session)
      if reason == :expiry, do: send(session, :expire), else: send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
      send(owner, :stop)
      assert {:error, :not_connected} = Transport.resolve_conn(profile: options.profile)
    end

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "unprivileged callers and non-confidential calls cannot pair", %{actor: actor} do
    request = %{op: :begin, owner: self()}
    assert {:error, _} = call(request, %{user_id: user_fixture().id})
    assert {:error, _} = call(request, actor, false)
    assert {:error, _} = call(request, nil)
  end

  defp call(request, actor, confidential \\ true) do
    Event.new(Map.put_new(request, :provider, :whatsapp), :channels,
      actor: actor,
      opts: [action: :pair_linked_device, confidential: confidential]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp qr(session, actor) do
    assert {:ok, %{phase: :challenge, challenge: %{type: :qr, value: qr}}} =
             call(%{op: :status, session: session}, actor)

    qr
  end

  defp account_id(session, actor) do
    assert {:ok, %{phase: :authenticated, account: %{external_id: id}}} =
             call(%{op: :status, session: session}, actor)

    id
  end

  defp await_phase(session, actor, phase, attempts \\ 100)
  defp await_phase(_, _, _, 0), do: false

  defp await_phase(session, actor, phase, attempts) do
    case call(%{op: :status, session: session}, actor) do
      {:ok, %{phase: ^phase}} ->
        true

      _ ->
        Process.sleep(10)
        await_phase(session, actor, phase, attempts - 1)
    end
  end
end
