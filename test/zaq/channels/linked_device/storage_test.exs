defmodule Zaq.Channels.LinkedDevice.StorageTest do
  use Zaq.DataCase, async: true

  alias Jido.Chat.WhatsApp.Transport.GuardedStorage

  alias Zaq.Channels.LinkedDevice.Storage
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Event
  alias Zaq.NodeRouter

  test "provisioning is idempotent and persisted terms survive a new callback instance" do
    config = connector()
    assert {:ok, binding} = bind(config.id)
    assert {:ok, ^binding} = bind(config.id)
    profile = "zaq_linked_device_#{config.id}"
    storage = Storage.new(binding: binding, profile: profile)
    value = %{private: <<255, 0, 10>>, nested: {:paired, [1, 2]}}
    assert :ok = Storage.put(storage, profile, :creds, :self, value)
    restored = Storage.new(binding: binding, profile: profile)
    assert {:ok, ^value} = Storage.get(restored, profile, :creds, :self)
    assert {:ok, [:self]} = Storage.list_keys(restored, profile, :creds)
    assert {:ok, [^profile]} = Storage.list_profiles(restored)
    assert {:error, :invalid_profile} = Storage.get(restored, "other", :creds, :self)
    assert :ok = Storage.delete(restored, profile, :creds, :self)
    assert :error = Storage.get(restored, profile, :creds, :self)
    assert :ok = Storage.clear(restored, profile)
    assert Connect.get_credential!(binding.credential_id).auth_kind == "api_key"
  end

  test "disabled and revoked access fails without recreating a grant" do
    config = connector()
    {:ok, binding} = bind(config.id)
    profile = "zaq_linked_device_#{config.id}"
    storage = Storage.new(binding: binding, profile: profile)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = bind(config.id)
    assert {:error, :connector_unavailable} = Storage.get(storage, profile, :creds, :self)
    Repo.update!(Ecto.Changeset.change(disabled, enabled: true))
    {:ok, _} = Connect.revoke_credential_grant(binding.credential_id, :org)
    assert {:error, :credential_revoked} = bind(config.id)
    assert {:error, :credential_revoked} = Storage.put(storage, profile, :creds, :self, %{})
  end

  test "the real adapter guard latches failed durable writes and notifies its connection" do
    config = connector()
    {:ok, binding} = bind(config.id)
    profile = "zaq_linked_device_#{config.id}"

    guard =
      GuardedStorage.new(
        storage: {Storage, binding: binding, profile: profile},
        notify: self()
      )

    assert :ok =
             GuardedStorage.put(guard, profile, :creds, :self, %{
               paired: true
             })

    Repo.update!(Ecto.Changeset.change(config, enabled: false))

    assert {:error, :storage_failed} =
             GuardedStorage.put(guard, profile, :creds, :self, %{
               paired: true
             })

    refute GuardedStorage.healthy?(guard)
    assert_received {:amarula, :error, :storage_failed}
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

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
