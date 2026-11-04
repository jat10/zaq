defmodule Zaq.Ingestion.PostProcessing.Request do
  @moduledoc "Durable generic processor reservation, independent of a processor's effective results."
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "post_processing_requests" do
    field :document_id, :integer
    field :resource_type, :string
    field :resource_id, :integer
    field :generation, :integer
    field :processor, :string
    field :request_key, :string
    field :payload, :map
    field :status, :string, default: "pending"
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
