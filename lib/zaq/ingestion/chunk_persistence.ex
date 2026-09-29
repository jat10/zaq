defmodule Zaq.Ingestion.ChunkPersistence do
  @moduledoc """
  Persists prepared chunks with the same metadata, language and half-vector rules
  for ordinary ingestion and standalone corpus preparation.

  Callers own document and checkpoint transactions. `invalidate?: false` lets a
  transactional caller invalidate language inventory only after commit.
  """

  alias Zaq.Ingestion.{Chunk, ChunkLanguages, DocumentChunker, FTSBackend, LanguageDetector}
  alias Zaq.Repo

  require Logger

  @doc "Validates and inserts a prepared chunk with a supplied embedding vector."
  @spec insert(struct(), integer(), integer(), list(), pos_integer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def insert(chunk, document_id, index, embedding, expected_dimension, opts \\ [])

  def insert(
        %DocumentChunker.Chunk{} = chunk,
        document_id,
        index,
        embedding,
        expected_dimension,
        opts
      )
      when is_list(opts) do
    with {:ok, half_vector} <- validate_vector(embedding, expected_dimension),
         {:ok, record} <- insert_chunk(chunk, document_id, index, half_vector) do
      if Keyword.get(opts, :invalidate?, true), do: ChunkLanguages.invalidate()
      {:ok, record}
    end
  end

  @doc "Checks whether a vector becomes all zero after half precision conversion."
  @spec zero_halfvec?(list()) :: boolean()
  def zero_halfvec?(embedding) do
    embedding |> Pgvector.HalfVector.new() |> zero_halfvec_data?()
  end

  defp validate_vector(embedding, dimension)
       when is_list(embedding) and is_integer(dimension) and dimension > 0 do
    cond do
      length(embedding) != dimension ->
        {:error, :dimension_mismatch}

      not Enum.all?(embedding, &is_number/1) ->
        {:error, :invalid_embedding}

      true ->
        build_half_vector(embedding)
    end
  end

  defp validate_vector(_, _), do: {:error, :invalid_embedding}

  defp build_half_vector(embedding) do
    half_vector = Pgvector.HalfVector.new(embedding)

    if zero_halfvec_data?(half_vector),
      do: {:error, :zero_norm_embedding},
      else: {:ok, half_vector}
  rescue
    ArgumentError -> {:error, :invalid_embedding}
  end

  defp zero_halfvec_data?(%Pgvector.HalfVector{
         data: <<_dimension::16, _reserved::16, values::binary>>
       }) do
    not Enum.any?(for(<<value::float-16 <- values>>, do: value), &(&1 != 0.0))
  end

  defp insert_chunk(%DocumentChunker.Chunk{} = chunk, document_id, index, half_vector) do
    language = LanguageDetector.detect(chunk.content)

    search_configuration =
      case FTSBackend.impl() do
        FTSBackend.Native ->
          FTSBackend.Native.configuration_for(language) |> String.split(".") |> List.last()

        FTSBackend.ParadeDB ->
          "simple"
      end

    attrs = %{
      document_id: document_id,
      content: chunk.content,
      chunk_index: index,
      section_path: chunk.section_path,
      metadata: Map.put(build_metadata(chunk), "search_configuration", search_configuration),
      embedding: half_vector,
      language: language
    }

    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        Logger.error("Failed to insert chunk #{index}: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  @doc "Builds section and locator metadata without duplicating chunk columns."
  @spec build_metadata(struct()) :: map()
  def build_metadata(%DocumentChunker.Chunk{} = chunk) do
    section_type = metadata_field(chunk.metadata, :section_type)

    base = %{
      section_id: chunk.section_id,
      section_type: section_type,
      section_level: metadata_field(chunk.metadata, :section_level),
      position: metadata_field(chunk.metadata, :position),
      tokens: chunk.tokens
    }

    base = put_locators(base, chunk)

    case section_type do
      value when value in [:figure, "figure"] ->
        figure_title = List.last(chunk.section_path) || ""
        Map.put(base, :figure_title, figure_title)

      _ ->
        base
    end
  end

  defp put_locators(meta, %DocumentChunker.Chunk{} = chunk) do
    meta
    |> put_page_line(:start, chunk.start_page, chunk.start_line)
    |> put_page_line(:end, chunk.end_page, chunk.end_line)
  end

  defp put_page_line(meta, key, page, line) when is_integer(page) and is_integer(line) do
    Map.put(meta, key, "P#{page}|L#{line}")
  end

  defp put_page_line(meta, _key, _page, _line), do: meta

  defp metadata_field(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_field(_metadata, _key), do: nil
end
