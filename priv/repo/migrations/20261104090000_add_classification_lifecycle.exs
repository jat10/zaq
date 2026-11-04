defmodule Zaq.Repo.Migrations.AddClassificationLifecycle do
  use Ecto.Migration

  def up do
    alter table(:documents) do
      add :generation, :bigint, null: false, default: 0
    end

    alter table(:ingest_jobs) do
      add :generation, :bigint
      add :classification_state, :string, null: false, default: "skipped"
      add :classification_error, :string
    end

    alter table(:ingest_chunk_jobs) do
      add :generation, :bigint
    end

    create constraint(:documents, :document_generation_nonnegative, check: "generation >= 0")

    create constraint(:ingest_jobs, :classification_run_state,
             check: "classification_state IN ('enabled', 'skipped')"
           )

    for table <- [:document_label_assignments, :chunk_label_assignments] do
      drop constraint(table, :manual_label_origin)

      alter table(table) do
        add :probability, :float
        add :definition_version, :integer
        add :generation, :bigint
        add :request_id, :uuid
      end

      create constraint(table, :label_origin, check: "origin IN ('manual', 'automatic')")

      create constraint(table, :label_probability,
               check: "probability IS NULL OR (probability >= 0 AND probability <= 1)"
             )

      create constraint(table, :automatic_label_result,
               check:
                 "origin = 'manual' OR (probability IS NOT NULL AND definition_version IS NOT NULL AND definition_version > 0 AND generation IS NOT NULL AND generation >= 0 AND request_id IS NOT NULL AND value IS NULL)"
             )
    end

    create table(:post_processing_requests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :resource_type, :string, null: false
      add :resource_id, :bigint, null: false
      add :generation, :bigint, null: false
      add :processor, :string, null: false
      add :request_key, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :post_processing_requests,
             [:processor, :resource_type, :resource_id, :generation, :request_key],
             name: :post_processing_identity
           )

    create index(:post_processing_requests, [:document_id, :status])

    create constraint(:post_processing_requests, :processing_resource_type,
             check: "resource_type IN ('document', 'chunk')"
           )

    create constraint(:post_processing_requests, :processing_status,
             check: "status IN ('pending', 'running', 'completed', 'failed', 'skipped')"
           )
  end

  def down do
    drop table(:post_processing_requests)

    for table <- [:document_label_assignments, :chunk_label_assignments] do
      # Automatic decisions have no PR1 representation; manual rows and values survive rollback.
      execute("DELETE FROM #{table} WHERE origin = 'automatic'")
      drop constraint(table, :automatic_label_result)
      drop constraint(table, :label_probability)
      drop constraint(table, :label_origin)

      alter table(table) do
        remove :probability
        remove :definition_version
        remove :generation
        remove :request_id
      end

      create constraint(table, :manual_label_origin, check: "origin = 'manual'")
    end

    drop constraint(:ingest_jobs, :classification_run_state)
    drop constraint(:documents, :document_generation_nonnegative)
    alter table(:ingest_chunk_jobs), do: remove(:generation)

    alter table(:ingest_jobs) do
      remove :generation
      remove :classification_state
      remove :classification_error
    end

    alter table(:documents), do: remove(:generation)
  end
end
