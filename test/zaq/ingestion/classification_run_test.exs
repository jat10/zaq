defmodule Zaq.Ingestion.ClassificationRunTest do
  use Zaq.DataCase, async: true
  import Zaq.AccountsFixtures
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Chunk, ClassificationRun, DocumentGeneration, IngestJob, Labels}
  alias Zaq.Ingestion.PostProcessing.{Request, Worker}
  alias Zaq.TestSupport.OpenAIStub

  defmodule Config do
    def get(:zaq, :node_router, _), do: Zaq.NodeRouter
    def get(_, _, default), do: default
  end

  defp configured(handler) do
    {_pid, endpoint} = OpenAIStub.start!(handler, self())

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "run-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})

    {:ok, _} =
      Labels.save_definition(%{name: "Automatic", targets: ["chunk"], automatic_chunk: true}, %{
        user_id: user.id
      })
  end

  defp record do
    %Record{
      id: Ecto.UUID.generate(),
      kind: :file,
      name: "run.md",
      attributes: %{"provider" => "gdrive", "config_id" => "run"}
    }
  end

  test "interactive failure creates no job until proceed-without choice; skip remains durable" do
    configured(fn _conn, _body -> {401, %{error: %{message: "not available"}}} end)
    file = record()

    assert {:error, {:classification_confirmation_required, :decision_unavailable}} =
             Ingestion.ingest_records([file], %{interactive: true}, config: Config)

    assert Repo.aggregate(IngestJob, :count) == 0

    assert {:ok, [job]} =
             Ingestion.ingest_records(
               [file],
               %{interactive: true, classification_choice: "proceed_without"},
               config: Config
             )

    assert job.classification_state == "skipped"
    assert Repo.reload!(job).classification_error == "skipped_by_user"
    context = ClassificationRun.context(job)

    {:ok, doc} =
      DocumentGeneration.replace(%{source: "skipped", content: "content"},
        classification_context: context
      )

    {:ok, _} =
      DocumentGeneration.insert_chunk(
        doc.id,
        doc.generation,
        %{document_id: doc.id, chunk_index: 1, content: "content"},
        classification_context: context
      )

    assert Repo.aggregate(Request, :count) == 0
  end

  test "unattended failure proceeds and reports the saved classification problem" do
    configured(fn _conn, _body -> {503, %{error: %{message: "offline"}}} end)
    assert {:ok, [job]} = Ingestion.ingest_records([record()], %{}, config: Config)
    assert job.classification_state == "skipped"
    assert job.classification_error == "decision_unavailable"

    assert {:ok, %ClassificationRun{state: "skipped"}} =
             ClassificationRun.prepare(
               %{
                 classification_decision: %ClassificationRun{error: "decision_unavailable"}
               },
               config: Config
             )
  end

  test "one automatic chunk label schedules every new chunk; later model errors leave ingestion intact" do
    configured(fn _conn, body ->
      request = Jason.decode!(body)

      if hd(request["questions"])["name"] == "ready" do
        {200,
         %{
           model: "gpt-6-luna",
           usage: %{},
           answers: [%{name: "ready", type: "predicate", probability: 1.0}]
         }}
      else
        {503, %{error: %{message: "mid-run failure"}}}
      end
    end)

    assert {:ok, [job]} = Ingestion.ingest_records([record()], %{}, config: Config)
    assert job.classification_state == "enabled"
    context = ClassificationRun.context(job)

    {:ok, doc} =
      DocumentGeneration.replace(%{source: "enabled", content: "content"},
        classification_context: context
      )

    for index <- 1..3 do
      {:ok, _} =
        DocumentGeneration.insert_chunk(
          doc.id,
          doc.generation,
          %{document_id: doc.id, chunk_index: index, content: "chunk #{index}"},
          classification_context: context
        )
    end

    requests = Repo.all(Request)
    assert length(requests) == 3

    for request <- requests do
      assert :ok =
               Worker.perform(
                 %Oban.Job{args: %{"request_id" => request.id}, attempt: 1, max_attempts: 3},
                 config: Config
               )

      assert Repo.reload!(request).status == "failed"
    end

    assert Chunk.count_by_document(doc.id) == 3
    assert Repo.reload!(job).status == "pending"
  end
end
