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
             Runner.retry(
               database,
               dataset.manifest["source_sha256"],
               snapshot.fingerprint,
               [
                 chunk_id
               ],
               snapshot.contract
             )

    assert {:ok, %{complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               embed_fun: fn _ -> {:ok, embedding()} end,
               pace_ms: 0
             )

    assert Enum.map(Repo.all(Attempt), & &1.kind) == [
             "request",
             "failure",
             "retry_requested",
             "request",
             "success"
           ]
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

  test "provider cooldown survives restart and blocks requests until Retry-After expires" do
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Alpha"}]}
    database = %{corpus: Repo}
    snapshot = snapshot()
    first = fn _ -> {:error, {:rate_limited, 1, %{status: 429}}} end

    assert {:ok, %{requests: 1, stopped: :cooldown}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               deadline_ms: 100,
               pace_ms: 0,
               embed_fun: first
             )

    assert Runner.inspect(database).run.request_count == 1
    assert Runner.inspect(database).run.attempt_limit == 3
    assert Repo.one!(Chunk).status == "pending"

    assert {:ok, %{requests: 0, stopped: :cooldown}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               deadline_ms: 100,
               pace_ms: 0,
               embed_fun: fn _ -> flunk("request sent during cooldown") end
             )

    Process.sleep(1_050)

    assert {:ok, %{requests: 1, complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               pace_ms: 0,
               embed_fun: fn _ -> {:ok, embedding()} end
             )

    assert Runner.inspect(database).run.request_count == 2
    assert Enum.count(Repo.all(Attempt), &(&1.kind == "request")) == 2
  end

  test "attempt budget persists across invocations and explicit retry resets it" do
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Alpha"}]}
    database = %{corpus: Repo}
    snapshot = snapshot()
    rate_limit = fn _ -> {:error, {:rate_limited, 0, %{status: 429}}} end

    assert {:ok, %{requests: 1, stopped: :request_budget}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               attempts: 2,
               max_requests: 1,
               pace_ms: 0,
               embed_fun: rate_limit
             )

    assert {:error, :attempt_limit_mismatch} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               attempts: 3,
               max_requests: 1,
               pace_ms: 0,
               embed_fun: fn _ -> flunk("changed attempt limit resumed") end
             )

    assert {:ok, %{requests: 1, failed: 1}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               attempts: 2,
               max_requests: 1,
               pace_ms: 0,
               embed_fun: rate_limit
             )

    chunk_id = Repo.one!(Chunk).id
    assert Repo.one!(Chunk).status == "failed"
    assert Runner.inspect(database).run.request_count == 2

    assert {:ok, [^chunk_id]} =
             Runner.retry(
               database,
               dataset.manifest["source_sha256"],
               snapshot.fingerprint,
               [
                 chunk_id
               ],
               snapshot.contract
             )

    assert {:ok, %{requests: 1, complete: true}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               attempts: 2,
               pace_ms: 0,
               embed_fun: fn _ -> {:ok, embedding()} end
             )

    assert Runner.inspect(database).run.request_count == 3
  end

  test "resume rejects a changed preparation contract without re-embedding completed chunks" do
    dataset = dataset()
    database = %{corpus: Repo}
    snapshot = snapshot()

    assert {:ok, %{requests: 1}} =
             Runner.ingest(dataset, database, snapshot,
               limit: 1,
               pace_ms: 0,
               embed_fun: fn _ -> {:ok, embedding()} end
             )

    changed = %{snapshot | contract: Map.put(snapshot.contract, "code_revision", "changed")}

    assert {:error, :run_contract_mismatch} =
             Runner.ingest(dataset, database, changed,
               limit: 2,
               pace_ms: 0,
               embed_fun: fn _ -> flunk("incompatible code resumed") end
             )

    assert Runner.inspect(database).run.request_count == 1
    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 1
  end

  test "benchmark preparation applies the production Markdown sanitizer" do
    dataset = %{dataset() | documents: [%{"doc_id" => "a", "content" => "Al\0pha"}]}
    database = %{corpus: Repo}

    assert {:ok, %{complete: true}} =
             Runner.ingest(dataset, database, snapshot(),
               limit: 1,
               pace_ms: 0,
               embed_fun: fn input ->
                 assert input == "Alpha"
                 {:ok, embedding()}
               end
             )

    assert Repo.one!(Zaq.Ingestion.Document).content == "Alpha"
    assert {:ok, %{documents: 1}} = CorpusIntegrity.complete(database, dataset)
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
      fingerprint: String.duplicate("b", 64),
      contract:
        Configuration.preparation_contract(%{
          dimension: 1536,
          model: "test-model",
          chunk_min_tokens: 1,
          chunk_max_tokens: 100
        })
    }
  end

  defp embedding, do: [1.0 | List.duplicate(0.0, 1535)]
end
