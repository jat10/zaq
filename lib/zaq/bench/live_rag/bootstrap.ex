defmodule Zaq.Bench.LiveRAG.Bootstrap do
  @moduledoc """
  Provisions only the tables needed in a disposable, isolated corpus database.

  The vector extension is an operator prerequisite. Ordinary ZAQ application
  migrations are deliberately not run in the corpus database.
  """

  alias Zaq.Bench.LiveRAG.Database
  alias Zaq.Ingestion.Chunk
  alias Zaq.Repo
  alias Zaq.Repo.ExtensionChecks

  @base_version 20_260_929_152_636
  @checkpoint_version 20_260_929_152_637
  @allowed_tables ~w(schema_migrations documents chunks liverag_runs liverag_documents liverag_chunks liverag_attempts)

  @doc "Checks isolation and creates or resumes the minimal corpus schema."
  @spec ensure(map(), pos_integer()) :: :ok | {:error, atom()}
  def ensure(database, dimension) when is_integer(dimension) and dimension > 0 do
    Database.with_corpus(database, fn -> ensure_in_corpus(dimension) end)
  end

  def ensure(_, _), do: {:error, :invalid_dimension}

  defp ensure_in_corpus(dimension) do
    with :ok <- check_tables(),
         :ok <- check_empty_before_bootstrap() do
      ExtensionChecks.require!(Repo.get_dynamic_repo(), :vector)

      migrate(
        @base_version,
        "20260929152636_create_liverag_corpus_base.exs",
        Zaq.Repo.Migrations.CreateLiveragCorpusBase
      )

      Chunk.create_table(dimension, native_fts: true)

      with :ok <- check_dimension(dimension) do
        migrate(
          @checkpoint_version,
          "20260929152637_create_liverag_checkpoint_tables.exs",
          Zaq.Repo.Migrations.CreateLiveragCheckpointTables
        )

        :ok
      end
    end
  end

  defp check_tables do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename NOT LIKE 'pg_%'",
        [],
        log: false
      )

    if Enum.all?(rows, fn [table] -> table in @allowed_tables end),
      do: :ok,
      else: {:error, :unexpected_corpus_schema}
  end

  defp check_empty_before_bootstrap do
    {:ok, %{rows: [[documents]]}} =
      Repo.query("SELECT to_regclass('public.documents') IS NOT NULL", [], log: false)

    if documents do
      {:ok, %{rows: [[runs]]}} =
        Repo.query("SELECT to_regclass('public.liverag_runs') IS NOT NULL", [], log: false)

      if runs or count_documents() == 0,
        do: :ok,
        else: {:error, :nonempty_unmanaged_corpus}
    else
      :ok
    end
  end

  defp count_documents do
    {:ok, %{rows: [[count]]}} = Repo.query("SELECT count(*) FROM documents", [], log: false)
    count
  end

  defp check_dimension(dimension) do
    {:ok, %{rows: [[actual]]}} =
      Repo.query(
        "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a WHERE a.attrelid = 'chunks'::regclass AND a.attname = 'embedding'",
        [],
        log: false
      )

    if actual == "halfvec(#{dimension})", do: :ok, else: {:error, :corpus_dimension_mismatch}
  end

  defp migrate(version, filename, module) do
    path = Application.app_dir(:zaq, "priv/bench/liverag/migrations/#{filename}")
    Code.require_file(path)
    Ecto.Migrator.up(Repo, version, module, dynamic_repo: Repo.get_dynamic_repo(), log: false)
  end
end
