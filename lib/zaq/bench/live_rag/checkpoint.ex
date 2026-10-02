defmodule Zaq.Bench.LiveRAG.Checkpoint do
  @moduledoc """
  Owns persisted corpus progress and a session-bound, generation-fenced run lease.

  A caller holds `with_lease/5` across bounded embedding work. The checked-out
  PostgreSQL session owns the advisory lock; every state transition verifies that
  same session still holds it and that the persisted generation matches. No
  transaction is kept open during provider requests.
  """

  import Ecto.Query

  alias Zaq.Bench.LiveRAG.Checkpoint.{Attempt, Chunk, Document, Lease, Run}
  alias Zaq.Bench.LiveRAG.Database
  alias Zaq.Ingestion.{ChunkLanguages, ChunkPersistence, DocumentChunker}
  alias Zaq.Ingestion.Document, as: IndexedDocument
  alias Zaq.Repo

  @lock_key1 1_514_225_953
  @lock_key2 1_129_270_865

  @doc "Runs one callback while holding the corpus database's exclusive session lock."
  @spec with_lease(
          %{corpus: pid() | atom()},
          String.t(),
          String.t(),
          (Lease.t() -> result),
          map()
        ) ::
          result | {:error, atom()}
        when result: var
  def with_lease(database, input_sha256, config_fingerprint, fun, contract \\ %{})
      when is_function(fun, 1) do
    if valid_hash?(input_sha256) and valid_hash?(config_fingerprint) and is_map(contract) do
      Database.with_corpus(database, fn ->
        checkout_lock(input_sha256, config_fingerprint, contract, fun)
      end)
    else
      {:error, :invalid_run_contract}
    end
  end

  @doc "Returns false when the process, connection, lock, or generation is stale."
  @spec owned?(Lease.t()) :: boolean()
  def owned?(%Lease{} = lease) do
    lease.owner == self() and Repo.get_dynamic_repo() == lease.repo and
      lock_held_by_current_session?(lease.backend_pid) and run_matches?(lease)
  rescue
    DBConnection.ConnectionError -> false
    Postgrex.Error -> false
  end

  @doc "Atomically records a source document and its deterministic prepared chunks."
  @spec prepare_document(Lease.t(), String.t(), String.t(), [struct()]) ::
          {:ok, struct()} | {:error, term()}
  def prepare_document(%Lease{} = lease, source_doc_id, content, chunks) do
    with :ok <- validate_preparation(source_doc_id, content, chunks) do
      transact(lease, fn -> prepare_in_transaction(lease, source_doc_id, content, chunks) end)
    end
  end

  defp checkout_lock(input_sha256, config_fingerprint, contract, fun) do
    Repo.checkout(fn -> run_with_lock(input_sha256, config_fingerprint, contract, fun) end,
      timeout: :infinity
    )
  end

  defp prepare_in_transaction(lease, source_doc_id, content, chunks) do
    case Repo.get_by(Document, run_id: lease.run_id, source_doc_id: source_doc_id) do
      nil -> insert_preparation(lease, source_doc_id, content, chunks)
      %Document{} = existing -> verify_preparation(existing, content, chunks)
    end
  end

  @doc "Returns unfinished chunks in source order without changing their state."
  @spec unfinished_chunks(Lease.t()) :: [Chunk.t()] | {:error, :stale_lease}
  def unfinished_chunks(%Lease{} = lease) do
    if owned?(lease) do
      Repo.all(
        from chunk in Chunk,
          join: document in Document,
          on: chunk.run_document_id == document.id,
          where: document.run_id == ^lease.run_id and chunk.status == "pending",
          order_by: [document.source_doc_id, chunk.chunk_index]
      )
    else
      {:error, :stale_lease}
    end
  end

  @doc "Freezes the per-chunk request limit for every resumed invocation."
  def ensure_attempt_limit(%Lease{} = lease, limit) when is_integer(limit) and limit > 0 do
    case transact(lease, fn -> freeze_attempt_limit!(lease, limit) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp freeze_attempt_limit!(lease, limit) do
    run = Repo.get!(Run, lease.run_id)

    cond do
      is_nil(run.attempt_limit) ->
        run |> Run.changeset(%{attempt_limit: limit}) |> Repo.update!()
        :ok

      run.attempt_limit == limit ->
        :ok

      true ->
        Repo.rollback(:attempt_limit_mismatch)
    end
  end

  @doc "Reserves one provider request and its per-chunk attempt before sending it."
  def reserve_request(%Lease{} = lease, chunk_id, max_attempts) do
    transact(lease, fn ->
      {_chunk, _document} = pending_chunk!(lease, chunk_id)

      latest_retry =
        Repo.one(
          from a in Attempt,
            where: a.run_chunk_id == ^chunk_id and a.kind == "retry_requested",
            select: max(a.id)
        ) || 0

      used =
        Repo.aggregate(
          from(a in Attempt,
            where: a.run_chunk_id == ^chunk_id and a.kind == "request" and a.id > ^latest_retry
          ),
          :count
        )

      if used >= max_attempts, do: Repo.rollback(:attempt_budget)
      record_attempt!(chunk_id, "request")
      run = Repo.get!(Run, lease.run_id)
      run |> Run.changeset(%{request_count: run.request_count + 1}) |> Repo.update!()
      used + 1
    end)
  end

  @doc "Persists the provider-wide Retry-After deadline for a later invocation."
  def cooldown(%Lease{} = lease, seconds) when is_integer(seconds) and seconds >= 0 do
    transact(lease, fn ->
      until = DateTime.add(DateTime.utc_now(), seconds, :second)
      run = Repo.get!(Run, lease.run_id)

      until =
        if run.cooldown_until && DateTime.compare(run.cooldown_until, until) == :gt,
          do: run.cooldown_until,
          else: until

      run |> Run.changeset(%{cooldown_until: until}) |> Repo.update!()
      until
    end)
  end

  @doc "Returns milliseconds remaining on the persisted provider cooldown."
  def cooldown_remaining(%Lease{} = lease) do
    case Repo.get!(Run, lease.run_id).cooldown_until do
      nil -> 0
      until -> max(DateTime.diff(until, DateTime.utc_now(), :millisecond), 0)
    end
  end

  @doc "Persists a vector and its completion checkpoint in one fenced transaction."
  @spec succeed(Lease.t(), integer(), struct(), list(), pos_integer()) ::
          {:ok, Chunk.t()} | {:error, term()}
  def succeed(%Lease{} = lease, chunk_id, prepared_chunk, embedding, dimension) do
    result =
      transact(lease, fn ->
        {checkpoint, document} = pending_chunk!(lease, chunk_id, prepared_chunk)

        persisted =
          case ChunkPersistence.insert(
                 prepared_chunk,
                 document.document_id,
                 checkpoint.chunk_index,
                 embedding,
                 dimension,
                 invalidate?: false
               ) do
            {:ok, record} -> record
            {:error, reason} -> Repo.rollback(reason)
          end

        checkpoint =
          checkpoint
          |> Chunk.changeset(%{status: "completed", persisted_chunk_id: persisted.id})
          |> Repo.update!()

        record_attempt!(checkpoint.id, "success")
        update_document_status!(document)
        checkpoint
      end)

    if match?({:ok, _}, result), do: ChunkLanguages.invalidate()
    result
  end

  @doc "Records a fixed, redacted failure code and leaves retry to an explicit request."
  @spec fail(Lease.t(), integer(), atom()) :: {:ok, Chunk.t()} | {:error, term()}
  def fail(%Lease{} = lease, chunk_id, code) when is_atom(code) do
    code = Atom.to_string(code)

    if String.match?(code, ~r/\A[a-z][a-z0-9_]*\z/) and byte_size(code) <= 64 do
      transact(lease, fn ->
        {chunk, document} = pending_chunk!(lease, chunk_id)
        updated = chunk |> Chunk.changeset(%{status: "failed"}) |> Repo.update!()
        record_attempt!(chunk.id, "failure", code)
        document |> Document.changeset(%{status: "failed"}) |> Repo.update!()
        updated
      end)
    else
      {:error, :invalid_error_code}
    end
  end

  def fail(%Lease{}, _, _), do: {:error, :invalid_error_code}

  @doc "Reopens only an explicitly named failed chunk and records the request."
  @spec retry_failed(Lease.t(), integer()) :: {:ok, Chunk.t()} | {:error, term()}
  def retry_failed(%Lease{} = lease, chunk_id) do
    transact(lease, fn ->
      {chunk, document} = owned_chunk!(lease, chunk_id)

      if chunk.status != "failed", do: Repo.rollback(:not_failed)

      updated = chunk |> Chunk.changeset(%{status: "pending"}) |> Repo.update!()
      record_attempt!(chunk.id, "retry_requested")
      document |> Document.changeset(%{status: "pending"}) |> Repo.update!()
      updated
    end)
  end

  @doc "Marks the run complete only when the expected document count and all vectors reconcile."
  @spec complete(Lease.t(), pos_integer()) :: {:ok, Run.t()} | {:error, term()}
  def complete(%Lease{} = lease, expected_documents)
      when is_integer(expected_documents) and expected_documents > 0 do
    transact(lease, fn ->
      actual_documents =
        Repo.aggregate(
          from(document in Document, where: document.run_id == ^lease.run_id),
          :count
        )

      unfinished =
        Repo.exists?(
          from chunk in Chunk,
            join: document in Document,
            on: chunk.run_document_id == document.id,
            where: document.run_id == ^lease.run_id and chunk.status != "completed"
        )

      if unfinished or actual_documents != expected_documents, do: Repo.rollback(:incomplete)
      Repo.get!(Run, lease.run_id) |> Run.changeset(%{status: "complete"}) |> Repo.update!()
    end)
  end

  def complete(%Lease{}, _), do: {:error, :invalid_expected_documents}

  defp pending_chunk!(lease, chunk_id, prepared_chunk \\ nil) do
    {chunk, document} = owned_chunk!(lease, chunk_id)
    if chunk.status != "pending", do: Repo.rollback(:not_pending)

    if prepared_chunk &&
         (not match?(%DocumentChunker.Chunk{}, prepared_chunk) or
            chunk.content_sha256 != sha256(prepared_chunk.content) or
            chunk.embedding_input_sha256 != sha256(prepared_chunk.embedding_input) or
            chunk.payload != payload(prepared_chunk)),
       do: Repo.rollback(:chunk_identity_mismatch)

    {chunk, document}
  end

  defp owned_chunk!(lease, chunk_id) do
    query =
      from chunk in Chunk,
        join: document in Document,
        on: chunk.run_document_id == document.id,
        where: chunk.id == ^chunk_id and document.run_id == ^lease.run_id,
        lock: "FOR UPDATE",
        select: {chunk, document}

    case Repo.one(query) do
      nil -> Repo.rollback(:unknown_chunk)
      pair -> pair
    end
  end

  defp record_attempt!(chunk_id, kind, code \\ nil) do
    number = Repo.aggregate(from(a in Attempt, where: a.run_chunk_id == ^chunk_id), :count) + 1

    %Attempt{}
    |> Attempt.changeset(%{
      run_chunk_id: chunk_id,
      attempt_number: number,
      kind: kind,
      error_code: code
    })
    |> Repo.insert!()
  end

  defp update_document_status!(document) do
    remaining =
      Repo.exists?(
        from chunk in Chunk,
          where: chunk.run_document_id == ^document.id and chunk.status != "completed"
      )

    if not remaining do
      document |> Document.changeset(%{status: "completed"}) |> Repo.update!()
    end
  end

  defp validate_preparation(source_doc_id, content, chunks) do
    if is_binary(source_doc_id) and source_doc_id != "" and is_binary(content) and
         String.trim(content) != "" and is_list(chunks) and chunks != [] and
         Enum.all?(
           chunks,
           &match?(
             %DocumentChunker.Chunk{content: value, embedding_input: input}
             when is_binary(value) and is_binary(input),
             &1
           )
         ),
       do: :ok,
       else: {:error, :invalid_preparation}
  end

  defp insert_preparation(lease, source_doc_id, content, chunks) do
    source = "liverag/#{source_doc_id}"

    indexed =
      case IndexedDocument.create(%{source: source, title: source_doc_id, content: content}) do
        {:ok, document} -> document
        {:error, _} -> Repo.rollback(:document_insert_failed)
      end

    prepared =
      %Document{}
      |> Document.changeset(%{
        run_id: lease.run_id,
        source_doc_id: source_doc_id,
        source_sha256: sha256(content),
        document_id: indexed.id,
        expected_chunks: length(chunks)
      })
      |> Repo.insert!()

    chunks
    |> Enum.with_index(1)
    |> Enum.each(fn {chunk, index} ->
      %Chunk{}
      |> Chunk.changeset(%{
        run_document_id: prepared.id,
        chunk_index: index,
        content_sha256: sha256(chunk.content),
        embedding_input_sha256: sha256(chunk.embedding_input),
        payload: payload(chunk)
      })
      |> Repo.insert!()
    end)

    prepared
  end

  defp verify_preparation(existing, content, chunks) do
    stored =
      Repo.all(
        from chunk in Chunk,
          where: chunk.run_document_id == ^existing.id,
          order_by: chunk.chunk_index
      )

    expected_hashes = Enum.map(chunks, &{sha256(&1.content), sha256(&1.embedding_input)})

    if existing.source_sha256 == sha256(content) and existing.expected_chunks == length(chunks) and
         Enum.map(stored, &{&1.content_sha256, &1.embedding_input_sha256}) == expected_hashes,
       do: existing,
       else: Repo.rollback(:preparation_conflict)
  end

  defp payload(chunk) do
    chunk
    |> Map.from_struct()
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp transact(lease, fun) do
    Repo.transaction(fn ->
      if owned?(lease), do: fun.(), else: Repo.rollback(:stale_lease)
    end)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp run_with_lock(input_sha256, config_fingerprint, contract, fun) do
    case Repo.query("SELECT pg_try_advisory_lock($1, $2)", [@lock_key1, @lock_key2], log: false) do
      {:ok, %{rows: [[true]]}} ->
        try do
          case claim_run(input_sha256, config_fingerprint, contract) do
            {:ok, lease} -> fun.(lease)
            error -> error
          end
        after
          Repo.query("SELECT pg_advisory_unlock($1, $2)", [@lock_key1, @lock_key2], log: false)
        end

      {:ok, %{rows: [[false]]}} ->
        {:error, :run_busy}

      {:error, _} ->
        {:error, :lock_unavailable}
    end
  end

  defp claim_run(input_sha256, config_fingerprint, contract) do
    {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [], log: false)
    token = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        case Repo.one(from run in Run, where: run.id == 1, lock: "FOR UPDATE") do
          nil ->
            %Run{}
            |> Run.changeset(%{
              id: 1,
              input_sha256: input_sha256,
              config_fingerprint: config_fingerprint,
              preparation_contract: contract,
              generation: 1,
              lease_token: token,
              backend_pid: backend_pid
            })
            |> Repo.insert!()

          %Run{} = run ->
            resume_run(run, input_sha256, config_fingerprint, contract, token, backend_pid)
        end
      end)

    case result do
      {:ok, run} ->
        {:ok,
         %Lease{
           run_id: run.id,
           generation: run.generation,
           token: token,
           backend_pid: backend_pid,
           owner: self(),
           repo: Repo.get_dynamic_repo()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_run(%Run{} = run, input_sha256, config_fingerprint, contract, token, backend_pid) do
    cond do
      run.input_sha256 != input_sha256 or run.config_fingerprint != config_fingerprint or
          run.preparation_contract != Jason.decode!(Jason.encode!(contract)) ->
        Repo.rollback(:run_contract_mismatch)

      run.status == "complete" ->
        Repo.rollback(:run_complete)

      true ->
        run
        |> Run.changeset(%{
          generation: run.generation + 1,
          lease_token: token,
          backend_pid: backend_pid
        })
        |> Repo.update!()
    end
  end

  defp run_matches?(lease) do
    case Repo.get(Run, lease.run_id) do
      %Run{generation: generation, lease_token: token, backend_pid: backend_pid} ->
        generation == lease.generation and token == lease.token and
          backend_pid == lease.backend_pid

      _ ->
        false
    end
  end

  defp lock_held_by_current_session?(backend_pid) do
    query = """
    SELECT pg_backend_pid() = $3 AND EXISTS (
      SELECT 1 FROM pg_locks
      WHERE locktype = 'advisory' AND mode = 'ExclusiveLock'
        AND pid = pg_backend_pid()
        AND classid = $1::oid AND objid = $2::oid AND objsubid = 2
    )
    """

    case Repo.query(query, [@lock_key1, @lock_key2, backend_pid], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp valid_hash?(value) when is_binary(value),
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp valid_hash?(_), do: false
end
