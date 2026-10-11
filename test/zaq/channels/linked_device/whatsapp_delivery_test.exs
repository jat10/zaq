defmodule Zaq.Channels.LinkedDevice.WhatsAppDeliveryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, Bridge, JidoChatBridge}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule Adapter do
    @moduledoc false
    def send_message(room, body, opts) do
      send(self(), {:sent, room, body, opts})
      {:ok, %{external_message_id: "sent-1"}}
    end

    def edit_message(room, id, body, opts) do
      send(self(), {:edited, room, id, body, opts})
      :ok
    end

    def start_typing(room, opts), do: notify({:typing, room, opts})
    def add_reaction(room, id, emoji, opts), do: notify({:reaction, room, id, emoji, opts})

    def remove_reaction(room, id, emoji, opts),
      do: notify({:remove_reaction, room, id, emoji, opts})

    def open_dm(id, opts) do
      send(self(), {:dm, id, opts})
      {:ok, id}
    end

    defp notify(message) do
      send(self(), message)
      :ok
    end
  end

  setup do
    previous = Application.fetch_env!(:zaq, :channels)
    Application.put_env(:zaq, :channels, put_in(previous, [:whatsapp, :adapter], Adapter))
    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, first: connector("First"), second: connector("Second")}
  end

  test "selected second connector reaches send and edit, with canonical receipt", %{
    second: config
  } do
    outgoing = %Outgoing{
      provider: :whatsapp,
      channel_id: "peer@s.whatsapp.net",
      body: "answer",
      routing_context: %{channel_config_id: config.id}
    }

    assert {:ok, %{message_id: "sent-1"}} = dispatch(outgoing, :deliver_outgoing)
    assert_received {:sent, "peer@s.whatsapp.net", "answer", opts}
    assert opts[:profile] == "zaq_linked_device_#{config.id}"

    assert {:ok, _} = dispatch(%{outgoing | metadata: %{message_id: "sent-1"}}, :deliver_outgoing)
    assert_received {:edited, _, "sent-1", "answer", edit_opts}
    assert edit_opts[:profile] == opts[:profile]
  end

  test "typing and other operations preserve the selected account", %{second: config} do
    details = Bridge.fetch_connection_details_for_config(config)

    assert :ok =
             dispatch(
               %{provider: :whatsapp, channel_id: "peer", channel_config_id: config.id},
               :send_typing
             )

    assert_received {:typing, "peer", opts}
    assert opts[:profile] == details.profile
    assert :ok = JidoChatBridge.add_reaction(:whatsapp, "peer", "msg", "👍", details)
    assert_received {:reaction, _, _, _, reaction_opts}
    assert reaction_opts[:profile] == details.profile
    assert :ok = JidoChatBridge.remove_reaction(:whatsapp, "peer", "msg", "👍", details)
    assert_received {:remove_reaction, _, _, _, remove_opts}
    assert remove_opts[:profile] == details.profile

    assert {:ok, "peer"} =
             dispatch(
               %{provider: :whatsapp, author_id: "peer", channel_config_id: config.id},
               :open_dm_channel
             )

    assert_received {:dm, "peer", dm_opts}
    assert dm_opts[:profile] == details.profile
  end

  test "ambiguous and missing selections never fall back to the first account" do
    assert {:error, _} =
             dispatch(
               %Outgoing{provider: :whatsapp, channel_id: "peer", body: "no"},
               :deliver_outgoing
             )

    assert {:error, _} =
             dispatch(
               %{provider: :whatsapp, channel_id: "peer", channel_config_id: -1},
               :send_typing
             )

    assert {:error, :missing_linked_device_profile} =
             JidoChatBridge.send_typing(:whatsapp, "peer", %{url: "", token: ""})

    refute_received {:sent, _, _, _}
    refute_received {:typing, _, _}
  end

  defp dispatch(request, action) do
    request
    |> Event.new(:channels, opts: [action: action])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp connector(name) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: name,
      provider: "whatsapp",
      kind: "retrieval",
      enabled: true
    })
    |> Repo.insert!()
  end
end
