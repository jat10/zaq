defmodule Zaq.Engine.Connect.LinkedDeviceState do
  @moduledoc "Encrypted protocol records scoped to a linked-device credential association."
  use Ecto.Schema
  import Ecto.Changeset

  schema "connect_linked_device_states" do
    belongs_to :linked_device, Zaq.Engine.Connect.LinkedDevice
    field :namespace, :string
    field :key, :string
    field :encrypted_value, :string, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(state, trusted_attrs) do
    state
    |> change(trusted_attrs)
    |> validate_required([:linked_device_id, :namespace, :key, :encrypted_value])
    |> foreign_key_constraint(:linked_device_id)
    |> unique_constraint([:linked_device_id, :namespace, :key])
  end
end
