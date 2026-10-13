defmodule Zaq.Engine.Connect.LegacyDeviceMigrationTest do
  use Zaq.DataCase, async: true
  alias Jido.Chat.WhatsApp.Storage.Split, as: Storage
  alias Zaq.Channels.LinkedDevice
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, LegacyDeviceMigration}
  alias Zaq.System.SecretConfig

  setup do
    Repo.query!(
      "CREATE TEMP TABLE connect_linked_devices (id bigint, channel_config_id bigint, credential_id bigint, profile text) ON COMMIT DROP"
    )

    Repo.query!(
      "CREATE TEMP TABLE connect_linked_device_states (linked_device_id bigint, namespace text, key text, encrypted_value text) ON COMMIT DROP"
    )

    :ok
  end

  test "paired sessions migrate atomically, retain credential IDs and can be restored without QR" do
    first = legacy(%{key: <<255, 0>>, paired: true})
    second = legacy(%{paired: true, key: "second"})
    assert {:ok, 2} = LegacyDeviceMigration.run()
    assert {:ok, 2} = LegacyDeviceMigration.run()
    assert Repo.aggregate(Grant, :count) == 2

    for {binding, expected} <- [
          {first, %{key: <<255, 0>>, paired: true}},
          {second, %{paired: true, key: "second"}}
        ] do
      profile = "zaq_linked_device_#{binding.channel_config_id}"
      assert Connect.get_credential!(binding.credential_id).auth_kind == "api_key"

      assert {:ok, ^expected} =
               Storage.get(
                 Storage.new(LinkedDevice.storage_options(binding, profile)),
                 profile,
                 :creds,
                 :self
               )

      %{rows: [[ciphertext]]} =
        Repo.query!("SELECT api_key FROM connect_grants WHERE credential_id = $1", [
          binding.credential_id
        ])

      assert SecretConfig.encrypted?(ciphertext)
    end
  end

  test "corrupt source rolls back every conversion" do
    first = legacy(%{paired: true})
    second = legacy(%{paired: true})

    Repo.query!(
      "UPDATE connect_linked_device_states SET encrypted_value = 'broken' WHERE linked_device_id = $1",
      [second.channel_config_id]
    )

    assert {:error, :legacy_state_unreadable} = LegacyDeviceMigration.run()
    assert Repo.get!(Credential, first.credential_id).auth_kind == "linked_device"
    assert Repo.aggregate(Grant, :count) == 0
    refute Repo.get!(ChannelConfig, first.channel_config_id).settings["credential_document_id"]
  end

  test "offline migration preserves serialized atoms without loading protocol modules" do
    legacy(%{paired: true})
    name = "migration_atom_" <> Ecto.UUID.generate()
    encoded = Base.encode64(<<131, 119, byte_size(name), name::binary>>)
    {:ok, ciphertext} = SecretConfig.encrypt(encoded)
    Repo.query!("UPDATE connect_linked_device_states SET encrypted_value = $1", [ciphertext])
    assert {:ok, 1} = LegacyDeviceMigration.run()
    [grant] = Repo.all(Grant)
    %{"creds" => records} = Jason.decode!(grant.api_key)["records"]
    [stored] = Map.values(records)
    assert Base.decode64!(stored) == encoded
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "disabled accounts migrate without activation and conflicting bindings are rejected" do
    binding = legacy(%{paired: true})
    config = Repo.get!(ChannelConfig, binding.channel_config_id)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:ok, 1} = LegacyDeviceMigration.run()
    refute Repo.reload!(disabled).enabled
    assert Repo.reload!(disabled).settings["credential_document_id"] == binding.credential_id

    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(disabled), settings: %{"credential_document_id" => 1})
    )

    assert {:error, :legacy_binding_conflict} = LegacyDeviceMigration.run()
  end

  defp legacy(value) do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: Ecto.UUID.generate(),
        provider: "whatsapp",
        kind: "retrieval"
      })
      |> Repo.insert!()

    credential =
      %Credential{}
      |> Ecto.Changeset.change(
        name: Ecto.UUID.generate(),
        provider: "whatsapp",
        auth_kind: "linked_device"
      )
      |> Repo.insert!()

    Repo.query!("INSERT INTO connect_linked_devices VALUES ($1, $1, $2, $3)", [
      config.id,
      credential.id,
      "zaq_linked_device_#{config.id}"
    ])

    encoded = value |> :erlang.term_to_binary() |> Base.encode64()
    {:ok, ciphertext} = SecretConfig.encrypt(encoded)
    key = :self |> :erlang.term_to_binary() |> Base.encode64()

    Repo.query!("INSERT INTO connect_linked_device_states VALUES ($1, 'creds', $2, $3)", [
      config.id,
      key,
      ciphertext
    ])

    %{channel_config_id: config.id, credential_id: credential.id}
  end
end
