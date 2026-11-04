defmodule Zaq.Ingestion.DocumentGeneration do
  @moduledoc """
  Serializes content replacement and final chunk insertion on the parent document.

  Embedding and parsing happen before these transactions. Every full ingestion
  advances generation, including identical content. Missing legacy identities are
  rejected; a delayed writer cannot attach its output to a newer generation.
  """
  import Ecto.Query
  alias Zaq.Ingestion.{Chunk, Document, PostProcessing}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias Zaq.Ingestion.PostProcessing.Request
  alias Zaq.Repo

  @doc "Captures an unchanged document for a partial retry without replacing its successful chunks."
  def resume(source, content, expected_generation \\ nil) do
    Repo.transaction(fn ->
      document =
        Document |> where([d], d.source == ^source) |> lock("FOR UPDATE") |> Repo.one()

      if is_nil(document), do: Repo.rollback(:missing_document)

      if document.content != content or
           (not is_nil(expected_generation) and document.generation != expected_generation),
         do: Repo.rollback(:stale_generation)

      document
    end)
  end

  def replace(attrs, opts \\ []) do
    Repo.transaction(fn ->
      document =
        case Document.upsert(attrs) do
          {:ok, document} -> document
          {:error, reason} -> Repo.rollback(reason)
        end

      document = lock!(document.id)

      document =
        document |> Ecto.Changeset.change(generation: document.generation + 1) |> Repo.update!()

      if Chunk.table_exists?(), do: Chunk.delete_by_document(document.id)

      Repo.delete_all(
        from a in DocumentAssignment,
          where: a.document_id == ^document.id and a.origin == :automatic
      )

      Repo.update_all(
        from(r in Request,
          where: r.document_id == ^document.id and r.status in ["pending", "running"]
        ),
        set: [status: "skipped", error: "obsolete_generation"]
      )

      schedule("document", document.id, document, opts)
      document
    end)
  end

  @doc "Inserts after comparing the captured generation under the same parent lock as replacement."
  def insert_chunk(document_id, generation, attrs, opts \\ [])

  def insert_chunk(document_id, generation, attrs, opts) when is_integer(generation) do
    Repo.transaction(fn ->
      document = lock!(document_id)
      if document.generation != generation, do: Repo.rollback(:stale_generation)
      Chunk.delete_by_document_and_index(document_id, attrs.chunk_index)

      case %Chunk{} |> Chunk.changeset(attrs) |> Repo.insert() do
        {:ok, chunk} ->
          schedule("chunk", chunk.id, document, opts)
          chunk

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:error, :not_found} ->
        {:error,
         Ecto.Changeset.add_error(
           Chunk.changeset(%Chunk{}, attrs),
           :document_id,
           "does not exist"
         )}

      result ->
        result
    end
  end

  def insert_chunk(_, _, _, _), do: {:error, :missing_generation}

  defp schedule(type, id, document, opts) do
    context = Keyword.get(opts, :classification_context, %{})

    if context[:classification_state] == "enabled" do
      case PostProcessing.schedule(
             %{type: type, id: id, document_id: document.id, generation: document.generation},
             context,
             opts
           ) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end
  end

  @doc "Removes a retry slot only while it still belongs to the captured generation."
  def discard_chunk(document_id, generation, index) do
    Repo.transaction(fn ->
      document = lock!(document_id)
      if document.generation != generation, do: Repo.rollback(:stale_generation)
      Chunk.delete_by_document_and_index(document_id, index)
    end)
  end

  @doc "Locks the canonical parent for persistence callers already inside a transaction."
  def lock!(id) do
    Repo.one(from d in Document, where: d.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end
end
