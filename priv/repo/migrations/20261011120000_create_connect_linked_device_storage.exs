defmodule Zaq.Repo.Migrations.CreateConnectLinkedDeviceStorage do
  use Ecto.Migration

  def change do
    create table(:connect_linked_devices) do
      add :channel_config_id, references(:channel_configs, on_delete: :restrict), null: false
      add :credential_id, references(:connect_credentials, on_delete: :restrict), null: false
      add :profile, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connect_linked_devices, [:channel_config_id])
    create unique_index(:connect_linked_devices, [:credential_id])
    create unique_index(:connect_linked_devices, [:profile])

    create table(:connect_linked_device_states) do
      add :linked_device_id, references(:connect_linked_devices, on_delete: :delete_all),
        null: false

      add :namespace, :text, null: false
      add :key, :text, null: false
      add :encrypted_value, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connect_linked_device_states, [:linked_device_id, :namespace, :key])
  end
end
