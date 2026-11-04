defmodule Zaq.Ingestion.LabelAutomationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Zaq.AccountsFixtures
  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Chunk, Document, IngestJob, Labels, PostProcessing}
  alias Zaq.Ingestion.Labels.{Automation, ChunkAssignment, DocumentAssignment}
  alias Zaq.Ingestion.PostProcessing.{Request, Worker}
  alias Zaq.Permissions
  alias Zaq.TestSupport.OpenAIStub

  defmodule Config do
    def get(:zaq, :node_router, _), do: Zaq.NodeRouter
    def get(_, _, default), do: default
  end

  setup do
    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        api_key: "decision-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, doc} = Document.create(%{source: Ecto.UUID.generate(), content: "A topic"})

    {:ok, label} =
      Labels.save_definition(
        %{name: "Topic", targets: ["document"], automatic_document: true},
        actor
      )

    resource = %{type: "document", id: doc.id, document_id: doc.id, generation: doc.generation}
    %{actor: actor, doc: doc, label: label, resource: resource, credential: credential}
  end

  defp reserve(ctx) do
    assert {:ok, [request]} =
             PostProcessing.schedule(ctx.resource, %{
               classification_state: "enabled",
               actor: ctx.actor
             })

    request
  end

  test "threshold equality uses captured settings and duplicate application is inert", ctx do
    request = reserve(ctx)
    assert request.payload["threshold"] == 80
    {:ok, _} = Zaq.System.save_rag_model_config(:decision, %{classification_threshold: 99})
    assert :ok = Automation.apply_result(request, 0.8)
    assignment = Repo.get_by!(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id)
    assert assignment.selected
    assert assignment.origin == :automatic
    assert assignment.probability == 0.8
    assert {:skip, :obsolete} = Automation.apply_result(request, 0.1)
    assert Repo.reload!(assignment) == assignment
    assert {:ok, []} = PostProcessing.schedule(ctx.resource, %{classification_state: "enabled"})
  end

  property "manual inclusion, exclusion and values dominate every delayed probability", ctx do
    request = reserve(ctx)

    {:ok, _} =
      Labels.edit_resource(
        ctx.resource,
        [%{label_id: ctx.label.id, expected_version: 0, operation: "add", value: "chosen"}],
        ctx.actor
      )

    check all(probability <- float(min: 0.0, max: 1.0)) do
      assert {:skip, :manual_override} = Automation.apply_result(request, probability)

      assignment =
        Repo.get_by!(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id)

      assert assignment.selected and assignment.origin == :manual and assignment.value == "chosen"
    end
  end

  test "definition changes invalidate pending results without clearing retained labels", ctx do
    request = reserve(ctx)
    assert :ok = Automation.apply_result(request, 0.9)
    assignment = Repo.get_by!(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id)

    assert {:ok, _} =
             Labels.save_definition(
               %{
                 id: ctx.label.id,
                 expected_version: ctx.label.lock_version,
                 name: "Changed topic",
                 targets: ["document"]
               },
               ctx.actor
             )

    assert {:skip, :obsolete} = Automation.apply_result(request, 0.01)
    assert Repo.reload!(assignment) == assignment
  end

  test "real routed provider failure is terminal and retains the prior result", ctx do
    assert :ok = Automation.apply_result(reserve(ctx), 0.9)
    prior = Repo.get_by!(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id)

    {:ok, _} =
      Labels.save_definition(
        %{
          id: ctx.label.id,
          expected_version: ctx.label.lock_version,
          name: "Updated",
          targets: ["document"]
        },
        ctx.actor
      )

    request = reserve(ctx)

    {_pid, endpoint} =
      OpenAIStub.start!(fn _conn, _body -> {503, %{error: %{message: "unavailable"}}} end, self())

    {:ok, _} = Zaq.System.update_ai_provider_credential(ctx.credential, %{endpoint: endpoint})
    job = %Oban.Job{args: %{"request_id" => request.id}, attempt: 1, max_attempts: 3}
    assert :ok = Worker.perform(job, config: Config)
    assert Repo.reload!(request).status == "failed"
    assert Repo.reload!(prior) == prior
    assert_receive {:openai_request, "POST", "/v1/decisions", _, _}
  end

  test "a skipped run never reserves even after configuration recovers", ctx do
    assert {:ok, []} = PostProcessing.schedule(ctx.resource, %{classification_state: "skipped"})
    assert Repo.aggregate(Request, :count) == 0
  end

  test "invalid probabilities and a finished reservation cannot write an assignment", ctx do
    request = reserve(ctx)

    for probability <- [-0.01, 1.01, nil, "0.9"] do
      assert {:error, :invalid_probability} = Automation.apply_result(request, probability)
    end

    assert :ok = PostProcessing.finish(request.id, "failed", "classification_failed")
    assert {:skip, :obsolete} = Automation.apply_result(request, 0.99)
    assert Repo.get_by(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id) == nil
  end

  test "a persisted run skip rejects a probability reserved before the skip", ctx do
    job =
      %IngestJob{}
      |> IngestJob.changeset(%{file_path: "run.md", classification_state: "enabled"})
      |> Repo.insert!()

    {:ok, [request]} =
      PostProcessing.schedule(ctx.resource, %{classification_state: "enabled", job_id: job.id})

    job |> IngestJob.changeset(%{classification_state: "skipped"}) |> Repo.update!()
    assert {:skip, :run_skipped} = Automation.apply_result(request, 0.99)
    assert Repo.get_by(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id) == nil
  end

  test "deleting a chunk makes its delayed classification inert", ctx do
    {:ok, label} =
      Labels.save_definition(
        %{
          id: ctx.label.id,
          expected_version: ctx.label.lock_version,
          name: ctx.label.name,
          targets: ["document", "chunk"],
          automatic_chunk: true
        },
        ctx.actor
      )

    chunk = Repo.insert!(%Chunk{document_id: ctx.doc.id, chunk_index: 1, content: "Deleted"})
    resource = %{ctx.resource | type: "chunk", id: chunk.id}
    {:ok, [request]} = PostProcessing.schedule(resource, %{classification_state: "enabled"})
    Repo.delete!(chunk)

    assert {:skip, :obsolete} = Automation.apply_result(request, 0.99)
    refute Repo.exists?(ChunkAssignment)
    assert Repo.get_by(DocumentAssignment, document_id: ctx.doc.id, label_id: label.id) == nil
  end

  test "revoked read access prevents delayed reclassification even when update remains", ctx do
    {_pid, endpoint} =
      OpenAIStub.start!(
        fn _conn, _body -> {503, %{error: %{message: "must not be called"}}} end,
        self()
      )

    {:ok, _} = Zaq.System.update_ai_provider_credential(ctx.credential, %{endpoint: endpoint})
    user = staff_fixture(%{must_change_password: false})
    {:ok, person} = People.create_person(%{full_name: "Delayed reader"})
    actor = %{user_id: user.id, person_id: person.id}

    {:ok, grant} =
      Permissions.grant(ctx.doc, %{person_id: person.id, access_rights: ["read", "update"]})

    {:ok, [request]} =
      PostProcessing.schedule(ctx.resource, %{
        classification_state: "enabled",
        actor: actor,
        authorize_actor: true
      })

    assert :ok = Permissions.revoke(ctx.doc, grant)
    {:ok, _} = Permissions.grant(ctx.doc, %{person_id: person.id, access_rights: ["update"]})

    assert {:skip, :obsolete} = Automation.perform(request, config: Config)
    assert {:skip, :obsolete} = Automation.apply_result(request, 0.99)
    assert Repo.get_by(DocumentAssignment, document_id: ctx.doc.id, label_id: ctx.label.id) == nil
    refute_receive {:openai_request, _, _, _, _}
  end
end
