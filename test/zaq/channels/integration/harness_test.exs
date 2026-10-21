defmodule Zaq.Channels.Integration.HarnessTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Engine.{Conversations, IncomingMessageRouting}
  alias Zaq.TestSupport.Channels.Integration.Fixtures

  test "case creates isolated sessions and restores the exact previous configuration" do
    alias Zaq.TestSupport.Channels.Integration.{Case, ContractFixture}
    previous = Application.fetch_env(:zaq, :channels)
    original_router = Application.fetch_env(:zaq, :node_router)

    on_exit(fn ->
      assert Application.fetch_env(:zaq, :channels) == previous
      assert Application.fetch_env(:zaq, :node_router) == original_router
    end)

    first = Case.channel_session(:mattermost, driver: ContractFixture)
    second = Case.channel_session(:mattermost, driver: ContractFixture)
    refute first.scope == second.scope
    refute first.connector.id == second.connector.id
    refute first.person.id == second.person.id
    refute first.handle.opaque == second.handle.opaque
    assert Application.get_env(:zaq, :node_router) == Zaq.NodeRouter

    on_exit(fn ->
      for pid <- [first.handle.opaque, second.handle.opaque] do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end
    end)
  end

  test "fixtures create a channel-eligible agent, scoped Person and actual routing rule" do
    scope = Ecto.UUID.generate()

    handle = %{
      provider: :mattermost,
      connector_attrs: %{url: "http://127.0.0.1:1", token: "test-token"},
      sender: %{id: "alice"},
      rooms: %{direct: "alice-dm", shared: "shared-room"}
    }

    fixtures = Fixtures.create!(handle, "http://127.0.0.1:1/v1", scope)
    assert fixtures.agent.active
    assert fixtures.agent.conversation_enabled
    rule = IncomingMessageRouting.get_rule(%{channel_config_id: fixtures.connector.id})
    assert rule.configured_agent_id == fixtures.agent.id
    assert rule.routing_mode == :agent
    person = People.get_person!(fixtures.person.id) |> Repo.preload(:channels)

    assert Enum.any?(person.channels, fn channel ->
             channel.channel_identifier == "alice" and
               channel.channel_config_id == fixtures.connector.id
           end)

    assert Conversations.list_conversations() == []
  end

  test "observer reports real delivery completion only for its connector" do
    alias Zaq.Channels.Api
    alias Zaq.Engine.Messages.Outgoing
    alias Zaq.TestSupport.Channels.Integration.Observer

    start_supervised!({Observer, owner: self(), scope: "observed", connector_id: 123})

    outgoing = %Outgoing{
      provider: :unregistered_contract_provider,
      channel_id: "dm",
      body: "Hello",
      routing_context: %{channel_config_id: 456}
    }

    event = Zaq.Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
    Api.handle_event(event, :deliver_outgoing, nil)

    outgoing = %{outgoing | routing_context: %{channel_config_id: 123}}
    event = %{event | request: outgoing}
    result = Api.handle_event(event, :deliver_outgoing, nil)
    assert {:error, {:no_bridge, :unregistered_contract_provider}} = result.response
    assert_receive {:channel_integration, "observed", :delivery, :return_from, ^result}
    refute_received {:channel_integration, "observed", :delivery, _, _}
  end
end
