defmodule Zaq.Ingestion.AutomaticStatusTest do
  use Zaq.DataCase, async: true
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels, PostProcessing}
  alias Zaq.Ingestion.Labels.Automation

  test "Not now and a failed replacement retain stale display, filters and authorized usage" do
    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{provider: "openai", api_key: "status-key"})

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, doc} = Document.create(%{source: "status", content: "text"})

    {:ok, label} =
      Labels.save_definition(
        %{name: "Status", targets: ["document"], automatic_document: true},
        actor
      )

    resource = %{type: "document", id: doc.id, document_id: doc.id, generation: doc.generation}
    {:ok, [request]} = PostProcessing.schedule(resource, %{classification_state: "enabled"})
    :ok = Automation.apply_result(request, 0.9)
    :ok = PostProcessing.finish(request.id, "completed")

    {:ok, label} =
      Labels.save_definition(
        %{
          id: label.id,
          expected_version: label.lock_version,
          description: "New definition",
          targets: ["document"]
        },
        actor
      )

    assert {:ok, %{labels: [%{selected: true, stale: true, origin: :automatic}]}} =
             Labels.resource_editor(resource, actor)

    assert {:ok, %{"status" => %{chips: [%{id: id, stale: true}]}}} =
             Labels.document_chips([doc.source], actor)

    assert id == label.id

    assert [doc.id] ==
             Document
             |> Document.filter_by_labels(%{"label_ids" => [label.id]})
             |> Repo.all()
             |> Enum.map(& &1.id)

    assert {:ok, %{^id => %{resources: 1}}} = Labels.value_summaries([label.id], actor)

    {:ok, [replacement]} =
      PostProcessing.schedule(resource, %{
        classification_state: "enabled",
        request_key: "confirmed"
      })

    :ok = PostProcessing.finish(replacement.id, "failed", "classification_failed")

    assert {:ok, %{labels: [%{selected: true, stale: true, processing_status: "failed"}]}} =
             Labels.resource_editor(resource, actor)

    assert {:error, :unauthorized} = Labels.resource_editor(resource, nil)
  end
end
