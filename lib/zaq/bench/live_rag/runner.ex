defmodule Zaq.Bench.LiveRAG.Runner do
  @moduledoc """
  Bounded, resumable ingestion of the pinned LiveRAG supporting corpus.

  Selection is deterministic by source document ID. A call processes at most
  its explicit document and request budgets, one request at a time. The
  checkpoint lease spans provider work but no database transaction does.
  """

  import Ecto.Query

  alias Zaq.Bench.LiveRAG.{Checkpoint, Configuration, Database}
  alias Zaq.Bench.LiveRAG.Checkpoint.{Attempt, Chunk, Document, Run}
  alias Zaq.Embedding.Client
  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.Ingestion.DocumentChunker.Chunk, as: PreparedChunk
  alias Zaq.Repo

  @default_max_requests 100
  @default_deadline_ms 300_000
  @default_pace_ms 100

  @doc "Ingests at most `limit` unfinished documents from a verified dataset."
  @spec ingest(map(), map(), Configuration.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest(%{documents: documents, manifest: manifest}, database, snapshot, opts)
      when is_list(documents) and is_list(opts) do
    with {:ok, policy} <- policy(opts),
         {:ok, client_config} <- Configuration.embedding_client_config(snapshot) do
      Checkpoint.with_lease(
        database,
        manifest["source_sha256"],
        snapshot.fingerprint,
        fn lease -> ingest_locked(lease, documents, snapshot, client_config, policy, opts) end
      )
    end
  end

  @doc "Reads progress and fixed error codes without modifying a checkpoint."
  @spec inspect(map()) :: map()
  def inspect(database) do
    Database.with_corpus(database, fn ->
      %{
        run:
          Repo.one(
            from r in Run,
              select: %{
                status: r.status,
                generation: r.generation,
                input_sha256: r.input_sha256,
                config_fingerprint: r.config_fingerprint
              }
          ),
        documents:
          Repo.all(from d in Document, group_by: d.status, select: {d.status, count(d.id)})
          |> Map.new(),
        chunks:
          Repo.all(from c in Chunk, group_by: c.status, select: {c.status, count(c.id)})
          |> Map.new(),
        failures:
          Repo.all(
            from a in Attempt,
              where: a.kind == "failure",
              order_by: [desc: a.id],
              limit: 100,
              select: %{chunk_id: a.run_chunk_id, attempt: a.attempt_number, code: a.error_code}
          )
      }
    end)
  end

  @doc "Explicitly reopens listed failed chunk IDs under the run lease."
  @spec retry(map(), String.t(), String.t(), [integer()]) :: {:ok, [integer()]} | {:error, term()}
  def retry(database, input_sha256, fingerprint, ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and Enum.uniq(ids) == ids do
      Checkpoint.with_lease(database, input_sha256, fingerprint, fn lease ->
        retry_ids(lease, ids)
      end)
    else
      {:error, :invalid_retry_ids}
    end
  end

  def retry(_, _, _, _), do: {:error, :invalid_retry_ids}

  defp retry_ids(lease, ids) do
    Repo.transaction(fn -> Enum.map(ids, &retry_id!(lease, &1)) end)
  end

  defp retry_id!(lease, id) do
    case Checkpoint.retry_failed(lease, id) do
      {:ok, _} -> id
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp policy(opts) do
    policy = %{
      limit: Keyword.get(opts, :limit),
      max_requests: Keyword.get(opts, :max_requests, @default_max_requests),
      deadline_ms: Keyword.get(opts, :deadline_ms, @default_deadline_ms),
      pace_ms: Keyword.get(opts, :pace_ms, @default_pace_ms),
      attempts: Keyword.get(opts, :attempts, 3)
    }

    if valid_integer?(policy.limit, 1..100) and
         valid_integer?(policy.max_requests, 1..1_000) and
         valid_integer?(policy.deadline_ms, 1..3_600_000) and
         valid_integer?(policy.pace_ms, 0..10_000) and
         valid_integer?(policy.attempts, 1..10) do
      {:ok, policy}
    else
      {:error, :invalid_run_policy}
    end
  end

  defp valid_integer?(value, range), do: is_integer(value) and value in range

  defp ingest_locked(lease, documents, snapshot, client_config, policy, opts) do
    selected = select_documents(lease, documents, policy.limit)
    deadline = System.monotonic_time(:millisecond) + policy.deadline_ms
    embed = Keyword.get(opts, :embed_fun, &default_embed(&1, client_config, policy))
    sleep = Keyword.get(opts, :sleep_fun, &Process.sleep/1)

    result =
      Enum.reduce_while(
        selected,
        %{selected: length(selected), prepared: 0, requests: 0, failed: 0, stopped: nil},
        fn source, state ->
          reduce_source(lease, source, snapshot, state, policy, deadline, embed, sleep)
        end
      )

    maybe_complete(lease, documents, result)
  end

  defp reduce_source(lease, source, snapshot, state, policy, deadline, embed, sleep) do
    if budget_exhausted?(lease, state, policy, deadline) do
      {:halt, %{state | stopped: stop_reason(lease, state, policy, deadline)}}
    else
      case ingest_document(lease, source, snapshot, state, policy, deadline, embed, sleep) do
        {:ok, next} -> {:cont, next}
        {:halt, next} -> {:halt, next}
      end
    end
  end

  defp select_documents(lease, documents, limit) do
    existing =
      Repo.all(
        from d in Document, where: d.run_id == ^lease.run_id, select: {d.source_doc_id, d.status}
      )
      |> Map.new()

    documents
    |> Enum.sort_by(& &1["doc_id"])
    |> Enum.filter(&(Map.get(existing, &1["doc_id"]) in [nil, "pending"]))
    |> Enum.take(limit)
  end

  defp ingest_document(lease, source, snapshot, state, policy, deadline, embed, sleep) do
    chunks =
      DocumentChunker.with_limits(snapshot.embedding, fn ->
        source["content"]
        |> DocumentChunker.parse_layout(format: :markdown)
        |> DocumentChunker.chunk_sections()
      end)

    case Checkpoint.prepare_document(lease, source["doc_id"], source["content"], chunks) do
      {:ok, document} ->
        rows =
          Repo.all(
            from c in Chunk,
              where: c.run_document_id == ^document.id and c.status == "pending",
              order_by: c.chunk_index
          )

        process_chunks(
          lease,
          rows,
          snapshot,
          %{state | prepared: state.prepared + 1},
          policy,
          deadline,
          embed,
          sleep
        )

      {:error, reason} ->
        {:halt, %{state | stopped: reason}}
    end
  end

  defp process_chunks(lease, rows, snapshot, state, policy, deadline, embed, sleep) do
    Enum.reduce_while(rows, {:ok, state}, fn row, {:ok, acc} ->
      if budget_exhausted?(lease, acc, policy, deadline) do
        {:halt, {:halt, %{acc | stopped: stop_reason(lease, acc, policy, deadline)}}}
      else
        process_chunk(lease, row, snapshot, acc, policy, embed, sleep)
      end
    end)
  end

  defp process_chunk(lease, row, snapshot, state, policy, embed, sleep) do
    prepared = hydrate_chunk(row.payload, snapshot.embedding)
    response = embed.(prepared.embedding_input)
    next = %{state | requests: state.requests + 1}

    outcome =
      case response do
        {:ok, vector} ->
          persist_vector(lease, row.id, prepared, vector, snapshot.embedding.dimension)

        {:error, reason} ->
          Checkpoint.fail(lease, row.id, error_code(reason))
      end

    reduce_outcome(outcome, next, sleep, policy.pace_ms)
  end

  defp persist_vector(lease, chunk_id, prepared, vector, dimension) do
    case Checkpoint.succeed(lease, chunk_id, prepared, vector, dimension) do
      {:error, reason}
      when reason in [:invalid_embedding, :dimension_mismatch, :zero_norm_embedding] ->
        Checkpoint.fail(lease, chunk_id, reason)

      other ->
        other
    end
  end

  defp reduce_outcome({:ok, %Chunk{status: "failed"}}, state, sleep, pace) do
    sleep_after(sleep, pace)
    {:cont, {:ok, %{state | failed: state.failed + 1}}}
  end

  defp reduce_outcome({:ok, _}, state, sleep, pace) do
    sleep_after(sleep, pace)
    {:cont, {:ok, state}}
  end

  defp reduce_outcome({:error, reason}, state, _sleep, _pace),
    do: {:halt, {:halt, %{state | stopped: reason}}}

  defp hydrate_chunk(payload, limits) do
    fields =
      PreparedChunk.__struct__()
      |> Map.from_struct()
      |> Map.keys()
      |> List.delete(:embedding_input)

    attrs = Map.new(fields, &{&1, payload[Atom.to_string(&1)]})
    chunk = struct(PreparedChunk, attrs)

    input =
      DocumentChunker.with_limits(limits, fn ->
        PreparedChunk.embedding_input(chunk.content, chunk.section_path)
      end)

    %{chunk | embedding_input: input}
  end

  defp maybe_complete(lease, documents, %{stopped: nil} = result) do
    case Checkpoint.complete(lease, length(documents)) do
      {:ok, _} -> {:ok, Map.put(result, :complete, true)}
      {:error, :incomplete} -> {:ok, Map.put(result, :complete, false)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_complete(_lease, _documents, result), do: {:ok, Map.put(result, :complete, false)}

  defp budget_exhausted?(lease, state, policy, deadline) do
    not Checkpoint.owned?(lease) or state.requests >= policy.max_requests or
      System.monotonic_time(:millisecond) >= deadline
  end

  defp stop_reason(lease, state, policy, deadline) do
    cond do
      not Checkpoint.owned?(lease) -> :stale_lease
      state.requests >= policy.max_requests -> :request_budget
      System.monotonic_time(:millisecond) >= deadline -> :deadline
    end
  end

  defp default_embed(input, config, policy) do
    Client.embed(input,
      config: config,
      redact_errors: true,
      max_attempts: policy.attempts,
      max_retry_delay_ms: min(policy.deadline_ms, 2_000)
    )
  end

  defp error_code({:api_error, _status}), do: :provider_error
  defp error_code({:rate_limited, _, _}), do: :rate_limited
  defp error_code(:embedding_transport_error), do: :transport_error
  defp error_code(:invalid_embedding_response), do: :invalid_response
  defp error_code(_), do: :embedding_failed

  defp sleep_after(_, 0), do: :ok
  defp sleep_after(sleep, duration), do: sleep.(duration)
end
