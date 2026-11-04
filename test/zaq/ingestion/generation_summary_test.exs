defmodule Zaq.Ingestion.GenerationSummaryTest do
  use Zaq.DataCase, async: true
  alias Zaq.Ingestion.{Document, DocumentGeneration, DocumentIngestionSummary, IngestJob}

  test "an obsolete parent cannot overwrite the replacement generation's display snapshot" do
    {:ok, old} = DocumentGeneration.replace(%{source: "generation-summary", content: "old"})

    job =
      Repo.insert!(%IngestJob{
        file_path: old.source,
        document_id: old.id,
        generation: old.generation,
        status: "processing"
      })

    {:ok, current} =
      DocumentGeneration.replace(%{
        source: old.source,
        content: "new",
        metadata: %{"marker" => "current"}
      })

    assert :ok = DocumentIngestionSummary.refresh(job, new_run: true)
    assert Repo.get!(Document, current.id).metadata == %{"marker" => "current"}

    assert {:error, :stale_generation} =
             DocumentIngestionSummary.refresh_inline(current.id, [], [], true,
               generation: old.generation
             )

    assert Repo.get!(Document, current.id).metadata == %{"marker" => "current"}
  end
end
