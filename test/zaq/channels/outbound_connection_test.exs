defmodule Zaq.Channels.OutboundConnectionTest do
  use Zaq.DataCase, async: true

  import Zaq.TestSupport.ChannelFileFixtures, only: [connector!: 2]

  alias Zaq.Channels.{Bridge, EmailBridge, JidoChatBridge}
  alias Zaq.Engine.Messages.Outgoing

  test "Jido inherits the existing lookup without a separate delivery callback" do
    config = connector!("mattermost", %{"send_on_file_failure" => false})
    expected = Bridge.fetch_connection_details_for_config(config)
    outgoing = %Outgoing{body: "Answer", channel_id: "room", provider: :mattermost}

    assert JidoChatBridge.fetch_connection_details_for_config(config) == expected

    assert {:ok, details} =
             JidoChatBridge.fetch_connection_details_for_config(config, outgoing: outgoing)

    assert details == expected
    refute Map.has_key?(details, :attachment_failure_policy)
    refute function_exported?(JidoChatBridge, :delivery_connection, 2)
    refute function_exported?(EmailBridge, :delivery_connection, 2)
  end
end
