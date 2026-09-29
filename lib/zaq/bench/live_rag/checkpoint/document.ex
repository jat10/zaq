defmodule Zaq.Bench.LiveRAG.Checkpoint.Document do
  @moduledoc "Persisted preparation state for one pinned supporting document."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Bench.LiveRAG.Checkpoint.Run
  alias Zaq.Ingestion.Document, as: IndexedDocument

  schema "liverag_documents" do
    belongs_to :run, Run, type: :integer
    belongs_to :document, IndexedDocument
    field :source_doc_id, :string
    field :source_sha256, :string
    field :expected_chunks, :integer
    field :status, :string, default: "pending"

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates source identity and expected chunk count."
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :run_id,
      :document_id,
      :source_doc_id,
      :source_sha256,
      :expected_chunks,
      :status
    ])
    |> validate_required([
      :run_id,
      :document_id,
      :source_doc_id,
      :source_sha256,
      :expected_chunks,
      :status
    ])
    |> validate_number(:expected_chunks, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ~w(pending completed failed))
    |> unique_constraint([:run_id, :source_doc_id])
    |> unique_constraint(:document_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:document_id)
    |> check_constraint(:expected_chunks, name: :liverag_documents_expected_nonnegative)
    |> check_constraint(:status, name: :liverag_documents_status_valid)
  end
end
