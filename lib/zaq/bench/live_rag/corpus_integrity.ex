defmodule Zaq.Bench.LiveRAG.CorpusIntegrity do
  @moduledoc """
  Reconciles a completed corpus and computes a restore-comparable fingerprint.

  The fingerprint covers document and chunk rows, vector text, schema indexes,
  and sequence state. It contains no credential or provider response data.
  """

  import Ecto.Query

  alias Zaq.Bench.LiveRAG.Checkpoint.{Document, Run}
  alias Zaq.Bench.LiveRAG.Database
  alias Zaq.Ingestion.Document, as: IndexedDocument
  alias Zaq.Ingestion.FTSBackend
  alias Zaq.Repo

  @doc "Checks every source document, chunk checkpoint and vector before export."
  @spec complete(map(), map()) :: {:ok, map()} | {:error, atom()}
  def complete(database, %{documents: sources, manifest: manifest}) do
    Database.with_corpus(database, fn -> complete_in_corpus(sources, manifest) end)
  end

  @doc "Hashes only the restorable document/chunk rows and structural metadata."
  @spec fingerprint(map()) :: map()
  def fingerprint(database) do
    Database.with_corpus(database, &fingerprint_in_corpus/0)
  end

  defp complete_in_corpus(sources, manifest) do
    with %Run{
           status: "complete",
           input_sha256: input_sha256,
           config_fingerprint: config,
           preparation_contract: contract
         } <- Repo.get(Run, 1),
         true <- input_sha256 == manifest["source_sha256"],
         :ok <- reconcile_documents(sources),
         {:ok, dimension} <- reconcile_chunks() do
      {:ok,
       fingerprint_in_corpus()
       |> Map.put(:dimension, dimension)
       |> Map.put(:input_sha256, input_sha256)
       |> Map.put(:config_fingerprint, config)
       |> Map.put(:preparation_contract, contract)}
    else
      _ -> {:error, :corpus_incomplete_or_mismatched}
    end
  end

  defp reconcile_documents(sources) do
    expected = Map.new(sources, &{&1["doc_id"], FTSBackend.sanitize_utf8_text(&1["content"])})

    rows =
      Repo.all(
        from checkpoint in Document,
          join: document in IndexedDocument,
          on: checkpoint.document_id == document.id,
          select:
            {checkpoint.source_doc_id, checkpoint.source_sha256, checkpoint.expected_chunks,
             checkpoint.status, document.source, document.content}
      )

    valid? =
      length(rows) == map_size(expected) and
        Enum.all?(rows, fn {id, hash, count, status, source, content} ->
          expected[id] == content and source == "liverag/#{id}" and
            hash == sha256(content) and count > 0 and status == "completed"
        end)

    if valid? and Repo.aggregate(IndexedDocument, :count) == length(rows),
      do: :ok,
      else: {:error, :document_mismatch}
  end

  defp reconcile_chunks do
    rows =
      Repo.query!(
        """
        SELECT cp.run_document_id, cp.chunk_index, cp.content_sha256, cp.status,
               cp.persisted_chunk_id, c.id, c.document_id, c.chunk_index, c.content,
               vector_dims(c.embedding), l2_norm(c.embedding) > 0
        FROM liverag_chunks cp
        JOIN liverag_documents d ON d.id = cp.run_document_id
        LEFT JOIN chunks c ON c.id = cp.persisted_chunk_id
        ORDER BY cp.run_document_id, cp.chunk_index
        """,
        [],
        log: false
      ).rows

    document_ids =
      Repo.all(from d in Document, select: {d.id, {d.document_id, d.expected_chunks}})
      |> Map.new()

    counts = Enum.frequencies_by(rows, &hd/1)
    dimensions = rows |> Enum.map(&Enum.at(&1, 9)) |> Enum.uniq()

    valid? =
      Enum.all?(document_ids, fn {id, {_indexed_id, expected}} ->
        Map.get(counts, id, 0) == expected
      end) and
        length(rows) == Repo.aggregate(Zaq.Ingestion.Chunk, :count) and
        Enum.all?(rows, &valid_chunk_row?(&1, document_ids)) and
        length(dimensions) == 1 and is_integer(hd(dimensions))

    if valid?, do: {:ok, hd(dimensions)}, else: {:error, :chunk_mismatch}
  end

  defp valid_chunk_row?(
         [
           document_id,
           index,
           hash,
           status,
           checkpoint_id,
           persisted_id,
           indexed_doc_id,
           persisted_index,
           content,
           _dimension,
           nonzero
         ],
         documents
       ) do
    {expected_document_id, expected_chunks} = Map.fetch!(documents, document_id)

    status == "completed" and is_binary(content) and index in 1..expected_chunks and
      checkpoint_id == persisted_id and
      indexed_doc_id == expected_document_id and persisted_index == index and
      hash == sha256(content) and nonzero == true
  end

  defp fingerprint_in_corpus do
    {:ok, %{rows: dimensions}} =
      Repo.query(
        "SELECT vector_dims(embedding) FROM chunks WHERE embedding IS NOT NULL LIMIT 1",
        [],
        log: false
      )

    dimension =
      case dimensions do
        [[value]] -> value
        _ -> nil
      end

    {:ok, %{rows: [[invalid_vectors]]}} =
      Repo.query(
        "SELECT count(*) FROM chunks WHERE embedding IS NULL OR vector_dims(embedding) <> $1 OR l2_norm(embedding) <= 0",
        [dimension],
        log: false
      )

    documents =
      Repo.query!(
        "SELECT source, title, content, content_type, metadata::text FROM documents ORDER BY source",
        [],
        log: false
      ).rows

    chunks =
      Repo.query!(
        """
        SELECT d.source, c.chunk_index, c.content, c.section_path, c.metadata::text,
               c.language, c.embedding::text
        FROM chunks c JOIN documents d ON d.id = c.document_id
        ORDER BY d.source, c.chunk_index
        """,
        [],
        log: false
      ).rows

    indexes =
      Repo.query!(
        "SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('documents', 'chunks') ORDER BY tablename, indexname",
        [],
        log: false
      ).rows

    sequences =
      for table <- ~w(documents chunks) do
        Repo.query!("SELECT last_value, is_called FROM #{table}_id_seq", [], log: false).rows
      end

    %{
      documents: length(documents),
      chunks: length(chunks),
      dimension: dimension,
      valid_vectors: is_integer(dimension) and invalid_vectors == 0,
      rows_sha256: sha256(Jason.encode!([documents, chunks])),
      indexes_sha256: sha256(Jason.encode!(indexes)),
      sequences_sha256: sha256(Jason.encode!(sequences))
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
