defmodule Zaq.Channels.JidoChatBridge.SessionStorageTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.Split
  alias Zaq.Channels.JidoChatBridge.SessionStorage
  alias Zaq.Engine.ChannelConfig

  test "saved ingress uses the adapter's stable binding and ignores connector overrides" do
    config = connector()

    config = %{
      config
      | settings: %{
          "jido_chat" => %{
            "ingress" => %{
              "profile" => "another_account",
              "storage_root" => "/tmp/untrusted",
              "config" => %{"sync_history" => true, "sync_full_history" => true}
            }
          }
        }
    }

    assert {:ok, ingress} = SessionStorage.prepare(config, Adapter)
    assert ingress.mode == :linked_device
    assert {:ok, ingress.profile} == SessionStorage.profile(config)
    assert {Split, storage_opts} = ingress.storage
    assert storage_opts[:context].channel_config_id == config.id
    refute ingress.sync_history
    refute ingress.sync_full_history
    refute Map.has_key?(ingress, :storage_root)

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("connector_#{config.id}",
               ingress: ingress,
               sink_mfa: {__MODULE__, :receive_payload, []}
             )

    {_module, :start_link, [worker_opts]} = spec.start
    assert worker_opts[:config].profile == ingress.profile
    assert worker_opts[:config].storage == ingress.storage
  end

  test "invalid and disabled connectors cannot yield saved options" do
    assert {:error, :invalid_connector} = SessionStorage.profile(%{id: nil})
    assert {:error, :invalid_connector} = SessionStorage.prepare(%{id: "42"}, Adapter)
    assert {:error, :unsupported} = SessionStorage.prepare(%{id: 42}, __MODULE__)

    config = connector()
    assert {:ok, _} = SessionStorage.prepare(config, Adapter)
    Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = SessionStorage.prepare(config, Adapter)
  end

  property "different durable bindings yield distinct stable adapter profiles" do
    check all(first <- positive_integer(), offset <- positive_integer()) do
      second = first + offset
      first_binding = %{channel_config_id: first, credential_id: 1}
      second_binding = %{channel_config_id: second, credential_id: 1}
      opts = [context: :runtime, document_mfa: {SessionStorage, :document, []}]
      first_profile = Adapter.connection_options(first_binding, opts).profile
      second_profile = Adapter.connection_options(second_binding, opts).profile

      refute first_profile == second_profile
      assert first_profile == Adapter.connection_options(first_binding, opts).profile
    end
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: Ecto.UUID.generate(),
      provider: "whatsapp",
      kind: "retrieval"
    })
    |> Repo.insert!()
  end
end
