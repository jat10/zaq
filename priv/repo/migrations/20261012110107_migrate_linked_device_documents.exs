defmodule Zaq.Repo.Migrations.MigrateLinkedDeviceDocuments do
  use Ecto.Migration

  def up do
    repo().query!(
      "LOCK TABLE connect_linked_devices, connect_linked_device_states, channel_configs, connect_credentials, connect_grants IN SHARE ROW EXCLUSIVE MODE"
    )

    case Zaq.Engine.Connect.LegacyDeviceMigration.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Linked-device migration blocked: #{reason}"
    end

    drop table(:connect_linked_device_states)
    drop table(:connect_linked_devices)
  end

  def down do
    raise "Session document migration is irreversible; restore the pre-migration database backup to roll back"
  end
end
