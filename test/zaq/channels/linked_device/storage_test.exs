defmodule Zaq.Channels.LinkedDevice.StorageTest do
  use Zaq.DataCase, async: true

  alias Jido.Chat.WhatsApp.Transport.GuardedStorage

  alias Zaq.Channels.LinkedDevice.{SessionStorage, Storage}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
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

  test "messaging updates stay in RAM without changing the credential or its notifications" do
    {storage, profile, binding} = storage()
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true})
    grant = Repo.get_by!(Grant, credential_id: binding.credential_id)
    jobs = Repo.aggregate(Oban.Job, :count)

    for namespace <- [:session, :sender_key] do
      assert :ok = Storage.put(storage, profile, namespace, "peer", %{counter: 1})
      assert :ok = Storage.put(storage, profile, namespace, "peer", %{counter: 2})
      assert {:ok, %{counter: 2}} = Storage.get(storage, profile, namespace, "peer")
      assert {:ok, ["peer"]} = Storage.list_keys(storage, profile, namespace)

      assert {:ok, []} =
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: to_string(namespace)
               })
    end

    assert Repo.get!(Grant, grant.id) == grant
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true, prekeys: [1]})
    refute Repo.get!(Grant, grant.id).api_key == grant.api_key
  end

  test "RAM callbacks retain current-binding checks and isolate accounts" do
    {storage, profile, binding} = storage()
    {other, other_profile, other_binding} = storage()
    assert :ok = Storage.put(storage, profile, :session, "peer", "first")
    assert :ok = Storage.put(other, other_profile, :session, "peer", "second")
    assert {:error, :invalid_profile} = Storage.get(storage, other_profile, :session, "peer")

    forged = %{storage | binding: %{binding | credential_id: other_binding.credential_id}}
    assert {:error, :invalid_binding} = Storage.get(forged, profile, :session, "peer")
    config = Repo.get!(ChannelConfig, binding.channel_config_id)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = Storage.get(storage, profile, :session, "peer")

    assert {:error, :connector_unavailable} =
             Storage.put(storage, profile, :session, "peer", "bad")

    Repo.update!(Ecto.Changeset.change(disabled, enabled: true))
    assert {:ok, "first"} = Storage.get(storage, profile, :session, "peer")
    assert :ok = Storage.clear(storage, profile)
    assert :error = Storage.get(storage, profile, :session, "peer")
    assert {:ok, "second"} = Storage.get(other, other_profile, :session, "peer")
    {:ok, _} = Connect.revoke_credential_grant(other_binding.credential_id, :org)
    assert {:error, :credential_revoked} = Storage.get(other, other_profile, :session, "peer")
    assert {:error, :credential_revoked} = Storage.delete(other, other_profile, :session, "peer")
    assert {:error, :credential_revoked} = Storage.list_keys(other, other_profile, :session)
  end

  test "preparation removes legacy sessions without changing pairing or current RAM state" do
    {storage, profile, binding} = storage()
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true})
    assert :ok = Storage.put(storage, profile, :app_state_sync_key, "sync", "retained")
    assert :ok = Storage.put(storage, profile, :session, "peer", "current")

    for namespace <- ["session", "sender_key"] do
      assert :ok =
               Connect.credential_document(%{
                 op: :put,
                 binding: binding,
                 namespace: namespace,
                 key: "legacy",
                 value: "old"
               })
    end

    assert :ok = Storage.prepare(storage)
    jobs = Repo.aggregate(Oban.Job, :count)
    assert :ok = Storage.prepare(storage)
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert {:ok, %{paired: true}} = Storage.get(storage, profile, :creds, :self)
    assert {:ok, "retained"} = Storage.get(storage, profile, :app_state_sync_key, "sync")
    assert {:ok, "current"} = Storage.get(storage, profile, :session, "peer")

    for namespace <- ["session", "sender_key"] do
      assert {:ok, []} =
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: namespace
               })
    end
  end

  defp storage do
    config = connector()
    {:ok, binding} = bind(config.id)
    profile = "zaq_linked_device_#{config.id}"
    storage = Storage.new(binding: binding, profile: profile)

    on_exit(fn ->
      SessionStorage.execute(
        {binding.channel_config_id, binding.credential_id, profile},
        %{op: :clear}
      )
    end)

    {storage, profile, binding}
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
