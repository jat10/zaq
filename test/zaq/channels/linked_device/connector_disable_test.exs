defmodule Zaq.Channels.LinkedDevice.ConnectorDisableTest do
  use Zaq.DataCase, async: false

  import Zaq.AccountsFixtures

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.ConnectorConfig.LifecycleLock
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle, LinkedDeviceConfirmation}
  alias Zaq.{Event, NodeRouter}

  defmodule OfflineTransport do
    def connect(config, opts) do
      Amarula.Testing.start_offline(
        profile: config.profile,
        storage: config.storage,
        parent_pid: Keyword.fetch!(opts, :parent)
      )
    end

    defdelegate stop(conn, opts), to: AmarulaClient
    defdelegate logout(conn, opts), to: AmarulaClient
  end

  defmodule OfflineAdapter do
    use Jido.Chat.Adapter

    defdelegate channel_type(), to: Adapter
    defdelegate capabilities(), to: Adapter
    defdelegate prepare_connection(opts), to: Adapter
    defdelegate connection_identity(binding), to: Adapter
    defdelegate provider_child_specs(opts), to: Adapter
    defdelegate send_message(room, text, opts), to: Adapter
    defdelegate transform_incoming(payload), to: Adapter
    defdelegate logout(listener), to: Adapter
    defdelegate cleanup_connection(binding, opts), to: Adapter

    def listener_child_specs(id, opts) do
      ingress = opts |> Keyword.fetch!(:ingress) |> Map.put(:transport, OfflineTransport)
      Adapter.listener_child_specs(id, Keyword.put(opts, :ingress, ingress))
    end
  end

  defmodule ActivationFailAdapter do
    use Jido.Chat.Adapter
    defdelegate channel_type(), to: Adapter
    defdelegate capabilities(), to: Adapter
    defdelegate prepare_connection(opts), to: Adapter
    defdelegate connection_identity(binding), to: Adapter
    defdelegate provider_child_specs(opts), to: Adapter
    defdelegate send_message(room, text, opts), to: Adapter
    defdelegate transform_incoming(payload), to: Adapter
    defdelegate logout(listener), to: Adapter
    defdelegate cleanup_connection(binding, opts), to: Adapter
    def listener_child_specs(_, _), do: {:error, :activation_failed}
  end

  defmodule CleanupBarrierRouter do
    def dispatch(%Event{opts: opts} = event) do
      result = NodeRouter.dispatch(event)

      if opts[:action] == :connector_logout and result.response == :ok do
        send(event.actor.observer, {:cleanup_completed, self()})

        receive do
          :persist_disable -> :ok
        end
      end

      result
    end
  end

  defmodule RpcRuntimeRouter do
    def dispatch(%Event{opts: opts} = event) do
      if opts[:action] == :connector_sync_runtime do
        Task.async(fn -> NodeRouter.dispatch(event) end) |> Task.await()
      else
        NodeRouter.dispatch(event)
      end
    end
  end

  setup do
    previous = Application.fetch_env!(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: OfflineAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    %{actor: %{user_id: super_admin_fixture(%{must_change_password: false}).id}}
  end

  for operation <- [:disable, :archive] do
    test "#{operation} cleans a saved account whose activation failed", %{actor: actor} do
      selected = connector(actor, "+15550005")
      other = connector(actor, "+15550006")
      assert {:ok, options} = JidoChatBridge.saved_connection_options(selected, OfflineAdapter)
      scope = Amarula.Storage.scope(options.storage)
      assert :ok = Amarula.Storage.put(scope, options.profile, :session, "peer", "ratchet")

      channels = Application.fetch_env!(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        put_in(channels, [:whatsapp, :adapter], ActivationFailAdapter)
      )

      assert {:error, :activation_failed} = JidoChatBridge.start_runtime(selected)

      assert {:error, :not_running} =
               Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(selected))

      case unquote(operation) do
        :disable ->
          assert {:ok, descriptor} = command(selected, :context, actor)
          assert {:ok, %{status: :disabled}} = dispatch(Map.put(descriptor, :op, :disable), actor)

        :archive ->
          event =
            Event.new(
              %{channel_config_id: selected.id, provider: selected.provider, kind: selected.kind},
              :engine,
              actor: actor,
              opts: [action: :archive_channel_connector, confidential: true]
            )

          assert {:ok, %{status: :archived}} = NodeRouter.dispatch(event).response
      end

      refute Repo.get!(ChannelConfig, selected.id).enabled
      assert Repo.get!(ChannelConfig, other.id).enabled
      selected = Repo.get!(ChannelConfig, selected.id)
      assert selected.settings["credential_document_id"]
      selected |> Ecto.Changeset.change(enabled: true, archived_at: nil) |> Repo.update!()
      assert :error = Amarula.Storage.get(scope, options.profile, :session, "peer")
      assert :error = Amarula.Storage.get(scope, options.profile, :creds, :bootstrap)
    end
  end

  test "missing saved binding is not provisioned during offline cleanup", %{actor: actor} do
    selected = connector(actor, "+15550007")
    settings = Map.delete(selected.settings, "credential_document_id")
    selected = selected |> Ecto.Changeset.change(settings: settings) |> Repo.update!()
    assert {:ok, descriptor} = command(selected, :context, actor)

    assert {:error, {:logout_failed, :invalid_binding}} =
             dispatch(Map.put(descriptor, :op, :disable), actor)

    assert Repo.get!(ChannelConfig, selected.id).enabled
    refute Repo.get!(ChannelConfig, selected.id).settings["credential_document_id"]
  end

  test "startup waits through cleanup and persistence, then rejects its stale snapshot", %{
    actor: actor
  } do
    selected = connector(actor, "+15550008")
    start_connector(selected)
    assert {:ok, descriptor} = command(selected, :context, actor)
    actor = Map.put(actor, :observer, self())

    disable =
      Task.async(fn ->
        ConnectorLifecycle.disable(Map.put(descriptor, :op, :disable), actor,
          router: CleanupBarrierRouter
        )
      end)

    assert_receive {:cleanup_completed, root}
    assert Repo.get!(ChannelConfig, selected.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(selected))

    start = Task.async(fn -> JidoChatBridge.start_runtime(selected) end)

    enable =
      Task.async(fn ->
        ConnectorLifecycle.enable(Map.put(descriptor, :op, :enable), actor)
      end)

    assert Task.yield(start, 30) == nil
    assert Task.yield(enable, 30) == nil
    send(root, :persist_disable)

    assert {:ok, %{status: :disabled, runtime: :synced}} = Task.await(disable)
    assert {:error, :connector_unavailable} = Task.await(start)
    assert {:error, :stale_connector} = Task.await(enable)
    assert {:error, :connector_unavailable} = JidoChatBridge.start_runtime(selected)
    refute Repo.get!(ChannelConfig, selected.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(selected))
  end

  test "explicit enable reuses the saved profile across an RPC-like runtime callback", %{
    actor: actor
  } do
    selected = connector(actor, "+15550010")
    selected = selected |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:ok, descriptor} = command(selected, :context, actor)
    request = Map.put(descriptor, :op, :enable)

    assert {:ok, %{status: :enabled, runtime: :synced}} =
             ConnectorLifecycle.enable(request, actor, router: RpcRuntimeRouter)

    bridge_id = JidoChatBridge.runtime_bridge_id(selected)
    assert {:ok, %{listener_pids: [first]}} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

    assert {:ok, %{status: :already_enabled, runtime: :synced}} =
             ConnectorLifecycle.enable(request, actor, router: RpcRuntimeRouter)

    assert {:ok, %{listener_pids: [^first]}} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

    assert Repo.get!(ChannelConfig, selected.id).settings["credential_document_id"] ==
             selected.settings["credential_document_id"]
  end

  test "enable revalidates privileges after waiting for lifecycle cleanup", %{actor: actor} do
    selected = connector(actor, "+15550011")
    selected = selected |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:ok, descriptor} = command(selected, :context, actor)

    enable =
      LifecycleLock.with_lock(selected.id, fn ->
        pending = Task.async(fn -> ConnectorLifecycle.enable(descriptor, actor) end)
        assert Task.yield(pending, 30) == nil
        staff = staff_fixture(%{must_change_password: false})

        Repo.get!(Zaq.Accounts.User, actor.user_id)
        |> Ecto.Changeset.change(role_id: staff.role_id)
        |> Repo.update!()

        pending
      end)

    assert {:error, :unauthorized} = Task.await(enable)
    refute Repo.get!(ChannelConfig, selected.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(selected))
  end

  test "runtime snapshot requires the confidential runtime capability", %{actor: actor} do
    selected = connector(actor, "+15550009")
    request = %{channel_config_id: selected.id, provider: selected.provider, kind: selected.kind}

    for opts <- [
          [action: :connector_runtime_context],
          [action: :connector_runtime_context, confidential: true]
        ] do
      assert {:error, :unauthorized} =
               NodeRouter.dispatch(Event.new(request, :engine, opts: opts)).response
    end
  end

  test "confirmed disable crosses real role boundaries and clears only its profile stores", %{
    actor: actor
  } do
    first = connector(actor, "+15550001")
    second = connector(actor, "+15550002")
    first_options = start_connector(first)
    second_options = start_connector(second)
    first_scope = Amarula.Storage.scope(first_options.storage)
    second_scope = Amarula.Storage.scope(second_options.storage)

    for {options, scope} <- [{first_options, first_scope}, {second_options, second_scope}] do
      assert :ok = Amarula.Storage.put(scope, options.profile, :creds, :logout_marker, "paired")
      assert :ok = Amarula.Storage.put(scope, options.profile, :session, "peer", "ratchet")
    end

    assert {:ok, descriptor} = command(first, :context, actor)

    assert {:ok, %{status: :disabled, runtime: :synced}} =
             dispatch(Map.put(descriptor, :op, :disable), actor)

    refute Repo.get!(ChannelConfig, first.id).enabled
    assert Repo.get!(ChannelConfig, second.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(first))

    assert {:ok, "paired"} =
             Amarula.Storage.get(second_scope, second_options.profile, :creds, :logout_marker)

    assert {:ok, "ratchet"} =
             Amarula.Storage.get(second_scope, second_options.profile, :session, "peer")

    # Re-enabling storage access cannot restore credentials erased by logout.
    Repo.get!(ChannelConfig, first.id) |> Ecto.Changeset.change(enabled: true) |> Repo.update!()

    assert :error =
             Amarula.Storage.get(first_scope, first_options.profile, :creds, :logout_marker)

    assert :error = Amarula.Storage.get(first_scope, first_options.profile, :session, "peer")
  end

  test "archive logs out and stops the selected saved profile before hiding it", %{actor: actor} do
    first = connector(actor, "+15550003")
    second = connector(actor, "+15550004")
    start_connector(first)
    start_connector(second)

    event =
      Event.new(
        %{channel_config_id: first.id, provider: first.provider, kind: first.kind},
        :engine,
        actor: actor,
        opts: [action: :archive_channel_connector, confidential: true]
      )

    assert {:ok, %{status: :archived, runtime: :synced}} = NodeRouter.dispatch(event).response

    assert %ChannelConfig{enabled: false, archived_at: %DateTime{}} =
             Repo.get!(ChannelConfig, first.id)

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(first))

    assert %ChannelConfig{enabled: true, archived_at: nil} = Repo.get!(ChannelConfig, second.id)

    assert {:ok, _} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(second))
  end

  defp connector(actor, phone) do
    {:ok, config} =
      LinkedDeviceConfirmation.save(%{
        attempt_id: Ecto.UUID.generate(),
        provider: "whatsapp",
        account: %{external_id: phone},
        owner_id: actor.user_id,
        credentials: %{{"creds", "bootstrap"} => "opaque"}
      })

    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    config
  end

  defp start_connector(config) do
    assert {:ok, options} = JidoChatBridge.saved_connection_options(config, OfflineAdapter)
    assert :ok = JidoChatBridge.start_runtime(config)
    options
  end

  defp command(config, op, actor),
    do:
      dispatch(
        %{op: op, channel_config_id: config.id, provider: config.provider, kind: config.kind},
        actor
      )

  defp dispatch(request, actor) do
    Event.new(request, :engine,
      actor: actor,
      opts: [action: :disable_channel_connector, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
