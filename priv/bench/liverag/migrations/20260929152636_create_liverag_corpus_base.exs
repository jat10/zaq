defmodule Zaq.Repo.Migrations.CreateLiveragCorpusBase do
  use Ecto.Migration

  def change do
    create table(:documents) do
      add :title, :string
      add :source, :string, null: false
      add :content, :text, null: false
      add :content_type, :string, null: false, default: "markdown"
      add :metadata, :map, default: %{}
      add :watch_status, :string, null: false, default: "unwatched"
      add :watch_requested_at, :utc_datetime
      add :watch_updated_at, :utc_datetime
      add :watch_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:source])
  end
end
