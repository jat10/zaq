defmodule Zaq.Ingestion.ClassificationSchemaTest do
  use Zaq.DataCase, async: true
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias Zaq.Ingestion.PostProcessing.Request

  test "manual values and versions survive independently of processing attempts" do
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, document} = Document.create(%{source: "schema-labels"})
    {:ok, label} = Labels.save_definition(%{name: "Schema", targets: ["document"]}, actor)

    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: document.id},
        [%{label_id: label.id, operation: "add", value: "manual", expected_version: 0}],
        actor
      )

    assignment = Repo.get_by!(DocumentAssignment, document_id: document.id, label_id: label.id)

    request =
      Repo.insert!(%Request{
        document_id: document.id,
        resource_type: "document",
        resource_id: document.id,
        generation: 0,
        processor: "labeling",
        request_key: "schema",
        payload: %{"label_id" => label.id},
        status: "pending"
      })

    assert assignment.origin == :manual
    assert assignment.value == "manual"
    assert assignment.lock_version == 1
    assert document.generation == 0
    assert Repo.reload!(assignment) == assignment
    assert Repo.reload!(request).status == "pending"
  end

  test "manual changes erase automatic provenance and keep an explicit exclusion" do
    previous = %DocumentAssignment{
      origin: :automatic,
      probability: 0.9,
      definition_version: 3,
      generation: 2,
      request_id: Ecto.UUID.generate(),
      label_id: 1,
      document_id: 1
    }

    current =
      previous |> DocumentAssignment.decision_changeset(false) |> Ecto.Changeset.apply_changes()

    assert current.origin == :manual
    refute current.selected
    assert current.probability == nil
    assert current.request_id == nil
    assert current.definition_version == nil
    assert current.generation == nil
  end
end
