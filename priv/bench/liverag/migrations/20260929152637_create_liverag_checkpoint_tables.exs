defmodule Zaq.Repo.Migrations.CreateLiveragCheckpointTables do
  use Ecto.Migration

  def change do
    create table(:liverag_runs, primary_key: false) do
      add :id, :integer, primary_key: true
      add :input_sha256, :string, null: false
      add :config_fingerprint, :string, null: false
      add :status, :string, null: false, default: "running"
      add :generation, :bigint, null: false, default: 0
      add :lease_token, :uuid
      add :backend_pid, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:liverag_runs, :liverag_runs_singleton, check: "id = 1")
    create constraint(:liverag_runs, :liverag_runs_generation_nonnegative, check: "generation >= 0")
    create constraint(:liverag_runs, :liverag_runs_status_valid, check: "status IN ('running', 'complete')")

    create table(:liverag_documents) do
      add :run_id, references(:liverag_runs, type: :integer, on_delete: :restrict), null: false
      add :source_doc_id, :text, null: false
      add :source_sha256, :string, null: false
      add :document_id, references(:documents, on_delete: :restrict), null: false
      add :expected_chunks, :integer, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:liverag_documents, [:run_id, :source_doc_id])
    create unique_index(:liverag_documents, [:document_id])
    create constraint(:liverag_documents, :liverag_documents_expected_nonnegative, check: "expected_chunks >= 0")
    create constraint(:liverag_documents, :liverag_documents_status_valid, check: "status IN ('pending', 'completed', 'failed')")

    create table(:liverag_chunks) do
      add :run_document_id, references(:liverag_documents, on_delete: :restrict), null: false
      add :chunk_index, :integer, null: false
      add :content_sha256, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :persisted_chunk_id, references(:chunks, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:liverag_chunks, [:run_document_id, :chunk_index])
    create unique_index(:liverag_chunks, [:persisted_chunk_id])
    create constraint(:liverag_chunks, :liverag_chunks_index_positive, check: "chunk_index > 0")
    create constraint(:liverag_chunks, :liverag_chunks_status_valid, check: "status IN ('pending', 'completed', 'failed')")
    create constraint(:liverag_chunks, :liverag_chunks_success_has_row,
             check: "status <> 'completed' OR persisted_chunk_id IS NOT NULL"
           )

    create table(:liverag_attempts) do
      add :run_chunk_id, references(:liverag_chunks, on_delete: :restrict), null: false
      add :attempt_number, :integer, null: false
      add :kind, :string, null: false
      add :error_code, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:liverag_attempts, [:run_chunk_id, :attempt_number])
    create constraint(:liverag_attempts, :liverag_attempts_number_positive, check: "attempt_number > 0")
    create constraint(:liverag_attempts, :liverag_attempts_kind_valid,
             check: "kind IN ('success', 'failure', 'retry_requested')"
           )
  end
end
