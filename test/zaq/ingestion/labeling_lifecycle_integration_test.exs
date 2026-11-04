defmodule Zaq.Ingestion.LabelingLifecycleIntegrationTest do
  use Zaq.DataCase, async: true
  import Ecto.Query
  import Zaq.AccountsFixtures

  alias Zaq.Ingestion.{
    Chunk,
    ClassificationRun,
    Document,
    DocumentGeneration,
    DocumentProcessor,
    IngestChunkJob,
    IngestChunkWorker,
    IngestJob,
    IngestWorker,
    Labels
  }

  alias Zaq.Ingestion.Labels.{ChunkAssignment, DocumentAssignment, Reclassification}
  alias Zaq.Ingestion.PostProcessing.{Request, Worker}
  alias Zaq.TestSupport.OpenAIStub

  defmodule Config do
    def get(:zaq, :document_processor, _), do: Zaq.Ingestion.DocumentProcessor
    def get(:zaq, :node_router, _), do: Zaq.NodeRouter
    def get(_, _, default), do: default
  end

  defp ingest(path) do
    {:ok, decision} = ClassificationRun.prepare(%{}, config: Config)

    job =
      %IngestJob{}
      |> IngestJob.changeset(%{
        file_path: path,
        mode: "async",
        classification_state: decision.state
      })
      |> Repo.insert!()

    assert :ok =
             IngestWorker.perform(
               %Oban.Job{args: %{"job_id" => job.id}, attempt: 1, max_attempts: 3},
               config: Config
             )

    for child <- Repo.all(from c in IngestChunkJob, where: c.ingest_job_id == ^job.id) do
      assert :ok =
               IngestChunkWorker.perform(
                 %Oban.Job{
                   args: %{"job_id" => job.id, "chunk_job_id" => child.id},
                   attempt: 1,
                   max_attempts: 5
                 },
                 config: Config
               )
    end

    job = Repo.reload!(job)
    assert job.status == "completed"
    job
  end

  defp classify(document_id, generation) do
    requests =
      Repo.all(
        from r in Request,
          where:
            r.document_id == ^document_id and r.generation == ^generation and
              r.status == "pending"
      )

    for request <- requests do
      assert :ok =
               Worker.perform(
                 %Oban.Job{args: %{"request_id" => request.id}, attempt: 1, max_attempts: 3},
                 config: Config
               )

      assert Repo.reload!(request).status == "completed"
    end
  end

  test "embedding completion after replacement cannot overwrite current chunks or progress" do
    owner = self()
    Zaq.SystemConfigFixtures.seed_embedding_config(%{dimension: 1536})

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      send(owner, {:embedding_started, self()})

      receive do
        :complete_embedding ->
          Req.Test.json(conn, %{data: [%{embedding: List.duplicate(0.1, 1536)}]})
      after
        5_000 -> flunk("embedding was never released")
      end
    end)

    {:ok, first} =
      DocumentGeneration.replace(%{source: Ecto.UUID.generate(), content: "Old content."})

    task =
      Task.async(fn ->
        DocumentProcessor.process_and_store_chunks_report(first.content, first.id,
          generation: first.generation
        )
      end)

    assert_receive {:embedding_started, embedding_pid}, 5_000

    {:ok, replacement} =
      DocumentGeneration.replace(%{
        source: first.source,
        content: "New content.",
        metadata: %{"ingestion" => %{"status" => "new generation"}}
      })

    {:ok, chunk} =
      DocumentGeneration.insert_chunk(replacement.id, replacement.generation, %{
        document_id: replacement.id,
        chunk_index: 1,
        content: replacement.content
      })

    send(embedding_pid, :complete_embedding)
    assert {:error, :stale_generation} = Task.await(task, 5_000)
    assert Chunk.list_by_document(replacement.id) == [chunk]
    assert Repo.reload!(replacement).metadata["ingestion"] == %{"status" => "new generation"}
  end

  test "real ingestion, classification, manual precedence, scoped reclassification and replacement" do
    counter = start_supervised!({Agent, fn -> %{embeddings: 0, probability: 0.95} end})

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      Agent.update(counter, &Map.update!(&1, :embeddings, fn n -> n + 1 end))
      Req.Test.json(conn, %{data: [%{embedding: List.duplicate(0.1, 1536)}]})
    end)

    Zaq.SystemConfigFixtures.seed_embedding_config(%{dimension: 1536})

    {_pid, endpoint} =
      OpenAIStub.start!(
        fn _conn, body ->
          questions = Jason.decode!(body)["questions"]

          answers =
            Enum.map(questions, fn q ->
              probability =
                if q["name"] == "ready", do: 1.0, else: Agent.get(counter, & &1.probability)

              %{name: q["name"], type: "predicate", probability: probability}
            end)

          {200, %{model: "gpt-6-luna", usage: %{}, answers: answers}}
        end,
        self()
      )

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "integration-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}

    {:ok, label} =
      Labels.save_definition(
        %{
          name: "Category",
          targets: ["document", "chunk"],
          automatic_document: true,
          automatic_chunk: true
        },
        actor
      )

    directory = Path.join(System.tmp_dir!(), "label-lifecycle-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "lifecycle.md")

    File.write!(
      path,
      Enum.map_join(1..4, "\n\n", fn n ->
        "## Section #{n}\n\n" <> String.duplicate("Useful classification content. ", 300)
      end)
    )

    job = ingest(path)
    document = Repo.get!(Document, job.document_id)
    chunks = Chunk.list_by_document(document.id)
    assert length(chunks) > 1
    classify(document.id, document.generation)
    assignment = Repo.get_by!(DocumentAssignment, document_id: document.id, label_id: label.id)
    assert assignment.selected and assignment.origin == :automatic

    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: document.id},
        [%{label_id: label.id, expected_version: assignment.lock_version, operation: "remove"}],
        actor
      )

    first = hd(chunks)
    chunk_assignment = Repo.get_by!(ChunkAssignment, chunk_id: first.id, label_id: label.id)

    {:ok, _} =
      Labels.edit_resource(
        %{type: "chunk", id: first.id},
        [
          %{
            label_id: label.id,
            expected_version: chunk_assignment.lock_version,
            operation: "add",
            value: "reviewed"
          }
        ],
        actor
      )

    {:ok, label} =
      Labels.save_definition(
        %{
          id: label.id,
          expected_version: label.lock_version,
          description: "Changed",
          targets: ["document", "chunk"]
        },
        actor
      )

    {:ok, preview} = Reclassification.preview(label.id, label.lock_version, actor)
    assert preview.affected_chunks == length(chunks)
    embeddings = Agent.get(counter, & &1.embeddings)
    Agent.update(counter, &Map.put(&1, :probability, 0.1))

    assert {:ok, %{requests: count}} =
             Reclassification.confirm(
               label.id,
               label.lock_version,
               preview.confirmation_token,
               actor,
               config: Config
             )

    assert count == length(chunks) - 1
    classify(document.id, document.generation)
    assert Agent.get(counter, & &1.embeddings) == embeddings

    assert %{selected: true, origin: :manual, value: "reviewed"} =
             Repo.get_by!(ChunkAssignment, chunk_id: first.id, label_id: label.id)

    replacement = ingest(path)
    assert replacement.document_id == document.id
    assert replacement.generation == document.generation + 1
    assert Enum.all?(chunks, &(Repo.get(Chunk, &1.id) == nil))
    assert Repo.get_by(ChunkAssignment, chunk_id: first.id) == nil
    classify(document.id, replacement.generation)

    assert Enum.all?(Chunk.list_by_document(document.id), fn chunk ->
             match?(
               %{selected: false, origin: :automatic},
               Repo.get_by!(ChunkAssignment, chunk_id: chunk.id, label_id: label.id)
             )
           end)

    assert %{selected: false, origin: :manual} =
             Repo.get_by!(DocumentAssignment, document_id: document.id, label_id: label.id)
  end
end
