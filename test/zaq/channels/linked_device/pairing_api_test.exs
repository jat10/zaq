defmodule Zaq.Channels.LinkedDevice.PairingApiTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Zaq.Channels.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event

  defmodule FailingRuntime do
    @moduledoc false
    def bridge_for(_), do: __MODULE__
    defdelegate fetch_channel_config(provider, id), to: Zaq.Channels.Bridge
    def sync_provider_runtime(_), do: {:error, :connection_start_failed}
  end

  test "retry propagates the actual runtime failure" do
    config = connector()
    admin = super_admin_fixture()

    event =
      Event.new(%{provider: :whatsapp, channel_config_id: config.id}, :channels,
        actor: %{user_id: admin.id},
        opts: [confidential: true, bridge_module: FailingRuntime]
      )

    assert Api.handle_event(event, :channel_retry_linked_device, nil).response ==
             {:error, :connection_start_failed}
  end

  test "pairing status and retry deny nil, unprivileged and non-confidential callers" do
    config = connector()
    admin = super_admin_fixture()
    user = user_fixture()

    for action <- [:channel_ingress_status, :channel_retry_linked_device],
        {actor, confidential} <- [
          {nil, true},
          {%{user_id: user.id}, true},
          {%{user_id: admin.id}, false}
        ] do
      assert {:error, :unauthorized} = call(config, action, actor, confidential)
    end
  end

  test "authorized status uses exact enabled connector and never trusts a supplied config" do
    config = connector()
    admin = super_admin_fixture()

    assert {:ok, %{phase: :disconnected, qr: nil}} =
             call(config, :channel_ingress_status, %{user_id: admin.id}, true)

    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:error, _} = call(config, :channel_ingress_status, %{user_id: admin.id}, true)
    assert {:error, _} = call(config, :channel_retry_linked_device, %{user_id: admin.id}, true)
  end

  defp call(config, action, actor, confidential) do
    Event.new(
      %{
        provider: :whatsapp,
        channel_config_id: config.id,
        config: %{config | provider: "telegram"}
      },
      :channels,
      actor: actor,
      opts: [action: action, confidential: confidential]
    )
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{name: "Pairing", provider: "whatsapp", kind: "retrieval"})
    |> Repo.insert!()
  end
end
