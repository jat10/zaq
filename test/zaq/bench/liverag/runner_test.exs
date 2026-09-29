defmodule Zaq.Bench.LiveRAG.RunnerTest do
  use Zaq.DataCase, async: false

  alias Ecto.Migration.Runner, as: MigrationRunner
  alias Zaq.Bench.LiveRAG.Checkpoint.{Attempt, Chunk, Document}
  alias Zaq.Bench.LiveRAG.{Configuration, CorpusIntegrity, Runner}
  alias Zaq.Repo.Migrations.CreateLiveragCheckpointTables
  alias Zaq.SystemConfigFixtures

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})

    migration =
      Path.expand(
        "../../../../priv/bench/liverag/migrations/20260929152637_create_liverag_checkpoint_tables.exs",
        __DIR__
      )

    Code.require_file(migration)

    MigrationRunner.run(
      Repo,
      Repo.config(),
      20_260_929_152_637,
      CreateLiveragCheckpointTables,
      :forward,
      :change,
      :up,
      log: false
    )

    :ok
  end

  test "ingest limit selects unfinished documents in source order and resumes without duplicate vectors" do
    dataset = dataset()
    snapshot = snapshot()
    database = %{corpus: Repo}

    embed = fn input ->
      send(self(), {:embedded, input})
      {:ok, embedding()}
    end

    assert {:ok, %{selected: 1, complete: false}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: embed,
               pace_ms: 0
             )

    assert_received {:embedded, "Alpha"}
    assert Repo.aggregate(Document, :count) == 1

    assert {:ok, %{selected: 1, complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: embed,
               pace_ms: 0
             )

    assert_received {:embedded, "Beta"}
    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 2
    assert Runner.inspect(database).documents == %{"completed" => 2}
  end

  test "failed chunks wait for an explicit retry and expose only a fixed error code" do
    database = %{corpus: Repo}
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Alpha"}]}
    snapshot = snapshot()

    assert {:ok, %{failed: 1, complete: false}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: fn _ -> {:error, "secret provider body"} end,
               pace_ms: 0
             )

    assert {:ok, %{selected: 0, complete: false}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: fn _ -> flunk("failed chunk retried automatically") end,
               pace_ms: 0
             )

    chunk_id = Repo.one!(Chunk).id
    assert [%{code: "embedding_failed"}] = Runner.inspect(database).failures

    assert {:ok, [^chunk_id]} =
             Runner.retry(database, dataset.manifest["source_sha256"], snapshot.fingerprint, [
               chunk_id
             ])

    assert {:ok, %{complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: fn _ -> {:ok, embedding()} end,
               pace_ms: 0
             )

    assert Enum.map(Repo.all(Attempt), & &1.kind) == ["failure", "retry_requested", "success"]
  end

  test "request budget stops scheduling and the next invocation resumes" do
    dataset = dataset()
    database = %{corpus: Repo}
    snapshot = snapshot()
    embed = fn _ -> {:ok, embedding()} end

    assert {:ok, %{requests: 1, stopped: :request_budget, complete: false}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 2,
               max_requests: 1,
               embed_fun: embed,
               pace_ms: 0
             )

    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 1

    assert {:ok, %{selected: 1, complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 2,
               max_requests: 1,
               embed_fun: embed,
               pace_ms: 0
             )
  end

  test "invalid vector is a fixed failed attempt and cannot be marked complete" do
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Alpha"}]}
    database = %{corpus: Repo}

    assert {:ok, %{failed: 1, complete: false}} =
             Runner.ingest(dataset, database, snapshot(),
               limit: 1,
               embed_fun: fn _ -> {:ok, List.duplicate(0.0, 1536)} end,
               pace_ms: 0
             )

    assert Repo.one!(Chunk).status == "failed"
    assert [%{code: "zero_norm_embedding"}] = Runner.inspect(database).failures
    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 0
  end

  test "export integrity reconciles document content, checkpoints, and nonzero vectors" do
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Alpha"}]}
    database = %{corpus: Repo}

    assert {:ok, %{complete: true}} =
             Runner.ingest(dataset, database, snapshot(),
               limit: 1,
               embed_fun: fn _ -> {:ok, embedding()} end,
               pace_ms: 0
             )

    assert {:ok, %{documents: 1, chunks: 1, valid_vectors: true, dimension: 1536}} =
             CorpusIntegrity.complete(database, dataset)

    altered = %{dataset | documents: [%{"doc_id" => "a", "content" => "Changed"}]}

    assert {:error, :corpus_incomplete_or_mismatched} =
             CorpusIntegrity.complete(database, altered)
  end

  defp dataset do
    %{
      manifest: %{"source_sha256" => String.duplicate("a", 64)},
      documents: [
        %{"doc_id" => "b", "content" => "Beta"},
        %{"doc_id" => "a", "content" => "Alpha"}
      ]
    }
  end

  defp snapshot do
    %Configuration{
      embedding: %{
        dimension: 1536,
        model: "test-model",
        chunk_min_tokens: 1,
        chunk_max_tokens: 100
      },
      provider: %{endpoint: "http://localhost:1234"},
      resolved_credential: %{auth_kind: "none", authentication: %{}},
      fingerprint: String.duplicate("b", 64)
    }
  end

  defp embedding, do: [1.0 | List.duplicate(0.0, 1535)]
end
