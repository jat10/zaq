defmodule Zaq.Bench.LiveRAG.Checkpoint.Chunk do
  @moduledoc "Persisted prepared chunk payload and its embedding completion state."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Bench.LiveRAG.Checkpoint.Document
  alias Zaq.Ingestion.Chunk, as: IndexedChunk

  schema "liverag_chunks" do
    belongs_to :run_document, Document
    belongs_to :persisted_chunk, IndexedChunk
    field :chunk_index, :integer
    field :content_sha256, :string
    field :payload, :map
    field :status, :string, default: "pending"

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Validates a prepared chunk and the completed-row invariant."
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :run_document_id,
      :persisted_chunk_id,
      :chunk_index,
      :content_sha256,
      :payload,
      :status
    ])
    |> validate_required([:run_document_id, :chunk_index, :content_sha256, :payload, :status])
    |> validate_number(:chunk_index, greater_than: 0)
    |> validate_inclusion(:status, ~w(pending completed failed))
    |> validate_success_row()
    |> unique_constraint([:run_document_id, :chunk_index])
    |> unique_constraint(:persisted_chunk_id)
    |> foreign_key_constraint(:run_document_id)
    |> foreign_key_constraint(:persisted_chunk_id)
    |> check_constraint(:status, name: :liverag_chunks_status_valid)
  end

  defp validate_success_row(changeset) do
    if get_field(changeset, :status) == "completed" and
         is_nil(get_field(changeset, :persisted_chunk_id)),
       do: add_error(changeset, :persisted_chunk_id, "is required when completed"),
       else: changeset
  end
end
