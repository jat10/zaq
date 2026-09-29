defmodule Zaq.Ingestion.ChunkPersistenceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Chunk, ChunkPersistence, Document, DocumentChunker}
  alias Zaq.SystemConfigFixtures

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    :ok
  end

  test "persists production chunk fields from a supplied embedding" do
    {:ok, document} = Document.create(%{source: "bench/#{Ecto.UUID.generate()}"})

    chunk = %DocumentChunker.Chunk{
      section_id: "section-1",
      content: "## Intro\n\nA supporting paragraph.",
      embedding_input: "Intro > A supporting paragraph.",
      section_path: ["Intro"],
      tokens: 6,
      metadata: %{section_type: :heading, section_level: 2, position: 0}
    }

    assert {:ok, %Chunk{} = persisted} =
             ChunkPersistence.insert(
               chunk,
               document.id,
               1,
               [0.1 | List.duplicate(0.0, 1535)],
               1536
             )

    persisted = Repo.get!(Chunk, persisted.id)

    assert persisted.content == chunk.content
    assert persisted.section_path == ["Intro"]
    assert persisted.chunk_index == 1
    assert persisted.metadata["section_id"] == "section-1"
    assert persisted.metadata["search_configuration"] in ["simple", "english"]
    assert %Pgvector.HalfVector{} = persisted.embedding
  end

  test "rejects wrong dimension and a vector that rounds to zero in half precision" do
    {:ok, document} = Document.create(%{source: "bench/#{Ecto.UUID.generate()}"})
    chunk = %DocumentChunker.Chunk{content: "Content", section_path: [], metadata: %{}}

    assert {:error, :dimension_mismatch} =
             ChunkPersistence.insert(chunk, document.id, 1, [0.1], 1536)

    assert {:error, :zero_norm_embedding} =
             ChunkPersistence.insert(chunk, document.id, 1, List.duplicate(1.0e-20, 1536), 1536)

    assert Repo.aggregate(Chunk, :count) == 0
  end
end
