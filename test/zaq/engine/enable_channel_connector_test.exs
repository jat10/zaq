defmodule Zaq.Engine.EnableChannelConnectorTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures

  alias Zaq.Engine.Actions.EnableChannelConnector
  alias Zaq.Engine.ChannelConfig
  alias Zaq.{Event, NodeRouter}

  defmodule ChannelsRouter do
    def dispatch(%Event{actor: actor} = event) do
      send(actor.observer, {:runtime_sync, event.request})
      %{event | response: Map.get(actor, :sync_result, :ok)}
    end
  end

  setup do
    user = super_admin_fixture(%{must_change_password: false})

    config = Zaq.WhatsAppFixtures.connector(%{name: "Saved account", enabled: false})

    context = %{
      actor: %{user_id: user.id, observer: self()},
      confidential: true,
      opts: [router: ChannelsRouter]
    }

    %{config: config, context: context, user: user}
  end

  test "enable is explicit, scoped, ID-only and repeatable", %{config: config, context: context} do
    assert {:ok, %{result: {:ok, descriptor}}} = run(context_request(config), context)
    refute Map.has_key?(descriptor, :token)
    request = Map.put(descriptor, :op, :enable)

    assert {:ok, %{result: {:ok, result}}} = run(request, context)
    assert result == %{channel_config_id: config.id, status: :enabled, runtime: :synced}
    assert Repo.get!(ChannelConfig, config.id).enabled

    assert_receive {:runtime_sync,
                    %{before_config: %{enabled: false}, after_config: %{id: id, enabled: true}}}

    assert id == config.id

    assert {:ok, %{result: {:ok, %{status: :already_enabled, runtime: :synced}}}} =
             run(request, context)

    assert Repo.get!(ChannelConfig, config.id).enabled
  end

  test "failure after persistence is pending and explicit retry converges", %{
    config: config,
    context: context
  } do
    assert {:ok, %{result: {:ok, descriptor}}} = run(context_request(config), context)
    request = Map.put(descriptor, :op, :enable)
    failing = put_in(context.actor[:sync_result], {:error, :startup_failed})

    assert {:ok, %{result: {:ok, %{status: :enabled, runtime: {:pending, :startup_failed}}}}} =
             run(request, failing)

    assert Repo.get!(ChannelConfig, config.id).enabled

    assert {:ok, %{result: {:ok, %{status: :already_enabled, runtime: :synced}}}} =
             run(request, context)
  end

  test "current super-admin and confidential context are required", %{
    config: config,
    context: context,
    user: user
  } do
    admin = admin_fixture(%{must_change_password: false})
    staff = staff_fixture(%{must_change_password: false})
    request = context_request(config)

    for actor <- [nil, %{}, %{user_id: admin.id}, %{user_id: staff.id}, %{owner_id: user.id}] do
      assert {:error, _} = run(request, %{context | actor: actor})
    end

    assert {:error, _} = run(request, %{context | confidential: false})
    assert {:ok, %{result: {:ok, descriptor}}} = run(request, context)
    user |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()
    assert {:error, _} = run(Map.put(descriptor, :op, :enable), context)
    refute Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:runtime_sync, _}
  end

  test "archived, stale and mismatched scope never start runtime", %{
    config: config,
    context: context
  } do
    assert {:ok, %{result: {:ok, descriptor}}} = run(context_request(config), context)
    request = Map.put(descriptor, :op, :enable)

    for bad <- [
          %{request | provider: "telegram"},
          %{request | kind: "ingestion"},
          %{request | channel_config_id: 0}
        ] do
      assert {:ok, %{result: {:error, :connector_not_found}}} = run(bad, context)
    end

    config |> Ecto.Changeset.change(name: "Edited") |> Repo.update!()
    assert {:ok, %{result: {:error, :stale_connector}}} = run(request, context)

    Repo.get!(ChannelConfig, config.id)
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert {:ok, %{result: {:error, :connector_not_found}}} = run(request, context)
    refute_received {:runtime_sync, _}
  end

  test "Engine event executes the Action rather than trusting a request actor", %{
    config: config,
    context: context
  } do
    request = Map.put(context_request(config), :actor, context.actor)

    event =
      Event.new(request, :engine, opts: [action: :enable_channel_connector, confidential: true])

    assert {:error, _} = NodeRouter.dispatch(event).response
    assert {:ok, descriptor} = NodeRouter.dispatch(%{event | actor: context.actor}).response
    refute Map.has_key?(descriptor, :token)
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  property "malformed commands cannot enable or dispatch", %{config: config, context: context} do
    check all(
            malformed <-
              one_of([
                constant(nil),
                integer(),
                string(:alphanumeric),
                list_of(integer()),
                map_of(integer(), integer())
              ]),
            max_runs: 25
          ) do
      assert {:ok, %{result: {:error, :invalid_request}}} = run(malformed, context)
      refute Repo.get!(ChannelConfig, config.id).enabled
      refute_received {:runtime_sync, _}
    end
  end

  defp context_request(config),
    do: %{
      op: :context,
      channel_config_id: config.id,
      provider: config.provider,
      kind: config.kind
    }

  defp run(request, context),
    do: Jido.Exec.run(EnableChannelConnector, %{request: request}, context)
end
