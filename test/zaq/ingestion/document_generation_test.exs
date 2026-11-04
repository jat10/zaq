defmodule Zaq.Ingestion.DocumentGenerationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Chunk, DocumentGeneration, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment

  test "partial retries retain chunks and generation, rejecting changed content or identity" do
    attrs = %{source: "retry-generation", content: "same"}
    {:ok, document} = DocumentGeneration.replace(attrs)

    {:ok, chunk} =
      DocumentGeneration.insert_chunk(document.id, document.generation, %{
        document_id: document.id,
        chunk_index: 1,
        content: "already indexed"
      })

    assert {:ok, ^document} =
             DocumentGeneration.resume(document.source, document.content, document.generation)

    assert Repo.reload!(chunk) == chunk
    assert {:error, :stale_generation} = DocumentGeneration.resume(document.source, "changed")

    assert {:error, :stale_generation} =
             DocumentGeneration.resume(document.source, document.content, document.generation - 1)

    assert {:error, :missing_document} = DocumentGeneration.resume("missing", "same")
    assert Repo.reload!(chunk) == chunk
  end

  test "same-content replacement advances identity and rejects delayed insertion" do
    attrs = %{source: "generation", content: "same"}
    assert {:ok, first} = DocumentGeneration.replace(attrs)
    chunk = %{document_id: first.id, chunk_index: 1, content: "old"}
    assert {:ok, old_chunk} = DocumentGeneration.insert_chunk(first.id, first.generation, chunk)
    assert {:ok, second} = DocumentGeneration.replace(attrs)
    assert second.id == first.id
    assert second.generation == first.generation + 1
    assert Repo.get(Chunk, old_chunk.id) == nil

    assert {:error, :stale_generation} =
             DocumentGeneration.insert_chunk(first.id, first.generation, chunk)

    assert {:error, :missing_generation} = DocumentGeneration.insert_chunk(first.id, nil, chunk)

    assert {:ok, fresh} =
             DocumentGeneration.insert_chunk(second.id, second.generation, %{
               chunk
               | content: "new"
             })

    assert fresh.content == "new"
  end

  test "document manual exclusions and values survive full replacement" do
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, doc} = DocumentGeneration.replace(%{source: "manual-generation", content: "old"})
    {:ok, label} = Labels.save_definition(%{name: "Manual", targets: ["document"]}, actor)

    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: doc.id},
        [%{label_id: label.id, operation: "add", value: "chosen", expected_version: 0}],
        actor
      )

    assignment = Repo.get_by!(DocumentAssignment, document_id: doc.id, label_id: label.id)
    assert {:ok, _} = DocumentGeneration.replace(%{source: doc.source, content: "replacement"})
    assert Repo.reload!(assignment) == assignment
  end

  property "generation increases for every replacement regardless of content equality" do
    check all(
            contents <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                min_length: 1,
                max_length: 5
              )
          ) do
      source = Ecto.UUID.generate()

      Enum.reduce(contents, 0, fn content, previous ->
        {:ok, document} = DocumentGeneration.replace(%{source: source, content: content})
        assert document.generation == previous + 1
        document.generation
      end)
    end
  end
end
