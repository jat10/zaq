defmodule Zaq.Engine.Connect.LinkedDevice do
  @moduledoc "Credential association for one persisted channel connector's linked-device session."
  use Ecto.Schema
  import Ecto.Changeset

  schema "connect_linked_devices" do
    belongs_to :channel_config, Zaq.Engine.ChannelConfig
    belongs_to :credential, Zaq.Engine.Connect.Credential
    field :profile, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(binding, trusted_attrs) do
    binding
    |> change(trusted_attrs)
    |> validate_required([:channel_config_id, :credential_id, :profile])
    |> unique_constraint(:channel_config_id)
    |> unique_constraint(:credential_id)
    |> unique_constraint(:profile)
    |> foreign_key_constraint(:channel_config_id)
    |> foreign_key_constraint(:credential_id)
  end
end
