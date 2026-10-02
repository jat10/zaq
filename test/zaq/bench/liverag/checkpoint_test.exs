defmodule Zaq.Bench.LiveRAG.CheckpointTest do
  use Zaq.DataCase, async: false

  alias Ecto.Migration.Runner
  alias Zaq.Bench.LiveRAG.Checkpoint
  alias Zaq.Bench.LiveRAG.Checkpoint.{Attempt, Chunk, Document, Run}
  alias Zaq.Ingestion.DocumentChunker
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

    Runner.run(
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

  test "migration constrains the singleton run and stores only identity fingerprints" do
    attrs = %{
      id: 1,
      input_sha256: String.duplicate("a", 64),
      config_fingerprint: String.duplicate("b", 64),
      generation: 0,
      status: "running"
    }

    assert {:ok, %Run{}} = %Run{} |> Run.changeset(attrs) |> Repo.insert()
    assert {:error, changeset} = %Run{} |> Run.changeset(%{attrs | id: 2}) |> Repo.insert()
    assert %{id: [_ | _]} = errors_on(changeset)
  end

  test "reacquiring the session lock advances the generation and fences an old lease" do
    input_sha = String.duplicate("a", 64)
    fingerprint = String.duplicate("b", 64)
    database = %{corpus: Repo}

    assert {:ok, first} =
             Checkpoint.with_lease(database, input_sha, fingerprint, fn lease ->
               assert Checkpoint.owned?(lease)
               {:ok, lease}
             end)

    refute Checkpoint.owned?(first)

    assert {:ok, second} =
             Checkpoint.with_lease(database, input_sha, fingerprint, fn lease ->
               assert Checkpoint.owned?(lease)
               {:ok, lease}
             end)

    assert second.generation == first.generation + 1
    assert second.token != first.token
    refute Checkpoint.owned?(first)
  end

  test "prepares document and chunk checkpoints atomically with exact embedding input" do
    chunk = %DocumentChunker.Chunk{
      content: "A supporting paragraph",
      embedding_input: "Secret transient prefix\n\nA supporting paragraph",
      section_path: ["Intro"],
      tokens: 4,
      metadata: %{section_type: :paragraph}
    }

    result =
      Checkpoint.with_lease(
        %{corpus: Repo},
        String.duplicate("a", 64),
        String.duplicate("b", 64),
        fn lease ->
          Checkpoint.prepare_document(lease, "source-a", "A supporting paragraph", [chunk])
        end
      )

    assert {:ok, %Document{} = prepared} = result
    assert prepared.expected_chunks == 1
    assert Repo.aggregate(Document, :count) == 1
    assert Repo.aggregate(Chunk, :count) == 1
    stored = Repo.one!(Chunk)

    assert stored.payload["embedding_input"] ==
             "Secret transient prefix\n\nA supporting paragraph"

    assert stored.embedding_input_sha256 == sha256(stored.payload["embedding_input"])
    assert stored.payload["content"] == "A supporting paragraph"
  end

  test "success commits vector and checkpoint once, and rejects an altered chunk" do
    chunk = prepared_chunk()

    assert {:ok, _} =
             leased(fn lease ->
               assert {:ok, _} =
                        Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])

               checkpoint = Repo.one!(Chunk)

               assert {:error, :chunk_identity_mismatch} =
                        Checkpoint.succeed(
                          lease,
                          checkpoint.id,
                          %{chunk | content: "changed"},
                          embedding(),
                          1536
                        )

               assert {:error, :dimension_mismatch} =
                        Checkpoint.succeed(lease, checkpoint.id, chunk, [1.0], 1536)

               assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 0
               assert Repo.get!(Chunk, checkpoint.id).status == "pending"

               assert {:ok, completed} =
                        Checkpoint.succeed(lease, checkpoint.id, chunk, embedding(), 1536)

               assert completed.persisted_chunk_id

               assert {:error, :not_pending} =
                        Checkpoint.succeed(lease, checkpoint.id, chunk, embedding(), 1536)

               assert {:error, :not_failed} = Checkpoint.retry_failed(lease, checkpoint.id)

               assert {:error, :incomplete} = Checkpoint.complete(lease, 2)
               assert {:ok, _} = Checkpoint.complete(lease, 1)
               {:ok, completed}
             end)

    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.one!(Document).status == "completed"
  end

  test "failure records only a redacted code and retry requires an explicit chunk ID" do
    chunk = prepared_chunk()

    assert {:ok, _} =
             leased(fn lease ->
               assert {:ok, _} =
                        Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])

               checkpoint = Repo.one!(Chunk)

               assert {:error, :invalid_error_code} =
                        Checkpoint.fail(lease, checkpoint.id, :"raw secret: token")

               assert {:ok, failed} = Checkpoint.fail(lease, checkpoint.id, :provider_timeout)
               assert failed.status == "failed"
               assert {:error, :incomplete} = Checkpoint.complete(lease, 1)

               assert {:error, :not_pending} =
                        Checkpoint.succeed(lease, checkpoint.id, chunk, embedding(), 1536)

               assert {:ok, pending} = Checkpoint.retry_failed(lease, checkpoint.id)
               assert pending.status == "pending"
               assert {:error, :not_failed} = Checkpoint.retry_failed(lease, checkpoint.id)
               {:ok, pending}
             end)

    assert Enum.map(Repo.all(Attempt), &{&1.attempt_number, &1.kind, &1.error_code}) ==
             [{1, "failure", "provider_timeout"}, {2, "retry_requested", nil}]

    assert Repo.one!(Document).status == "pending"
  end

  test "released lease cannot commit a late embedding" do
    chunk = prepared_chunk()

    assert {:ok, lease} =
             leased(fn lease ->
               assert {:ok, _} =
                        Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])

               {:ok, lease}
             end)

    checkpoint = Repo.one!(Chunk)

    assert {:error, :stale_lease} =
             Checkpoint.succeed(lease, checkpoint.id, chunk, embedding(), 1536)

    assert Repo.aggregate(Zaq.Ingestion.Chunk, :count) == 0
  end

  test "preparation resumes idempotently and rejects changed source content" do
    chunk = prepared_chunk()

    assert {:ok, _} =
             leased(fn lease ->
               assert {:ok, first} =
                        Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])

               assert {:ok, same} =
                        Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])

               assert first.id == same.id

               assert {:error, :preparation_conflict} =
                        Checkpoint.prepare_document(
                          lease,
                          "source-a",
                          "Different source content",
                          [chunk]
                        )

               assert {:error, :preparation_conflict} =
                        Checkpoint.prepare_document(
                          lease,
                          "source-a",
                          chunk.content,
                          [%{chunk | embedding_input: "changed input"}]
                        )

               {:ok, same}
             end)

    assert Repo.aggregate(Document, :count) == 1
    assert Repo.aggregate(Chunk, :count) == 1
  end

  test "a crashed owner releases the lock and a replacement advances its fence" do
    chunk = prepared_chunk()

    assert_raise RuntimeError, "worker crashed", fn ->
      leased(fn lease ->
        assert {:ok, _} = Checkpoint.prepare_document(lease, "source-a", chunk.content, [chunk])
        raise "worker crashed"
      end)
    end

    assert Repo.aggregate(Document, :count) == 1

    assert {:ok, _} =
             leased(fn lease ->
               assert lease.generation == 2
               assert length(Checkpoint.unfinished_chunks(lease)) == 1
               {:ok, lease}
             end)
  end

  defp leased(fun),
    do:
      Checkpoint.with_lease(
        %{corpus: Repo},
        String.duplicate("a", 64),
        String.duplicate("b", 64),
        fun
      )

  defp embedding, do: [1.0 | List.duplicate(0.0, 1535)]
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp prepared_chunk do
    %DocumentChunker.Chunk{
      content: "A supporting paragraph",
      embedding_input: "Transient only",
      section_path: ["Intro"],
      tokens: 4,
      metadata: %{section_type: :paragraph}
    }
  end
end
