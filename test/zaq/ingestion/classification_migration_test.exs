unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddClassificationLifecycle) do
  Code.require_file(
    "../../../priv/repo/migrations/20261104090000_add_classification_lifecycle.exs",
    __DIR__
  )
end

defmodule Zaq.Ingestion.ClassificationMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias Zaq.Repo.Migrations.AddClassificationLifecycle
  import Zaq.AccountsFixtures

  test "rollback and upgrade retain PR1 manual inclusion, exclusion, value and versions" do
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, doc} = Document.create(%{source: "upgrade-manual"})
    {:ok, label} = Labels.save_definition(%{name: "Upgrade", targets: ["document"]}, actor)

    original =
      Repo.insert!(%DocumentAssignment{
        document_id: doc.id,
        label_id: label.id,
        selected: false,
        value: nil,
        origin: :manual,
        lock_version: 7
      })

    assert :ok =
             Ecto.Migrator.down(Repo, 20_261_104_090_000, AddClassificationLifecycle,
               log: false,
               migration_lock: false
             )

    assert [[false, "manual", 7]] =
             Repo.query!(
               "SELECT selected, origin, lock_version FROM document_label_assignments WHERE id = $1",
               [original.id]
             ).rows

    assert :ok =
             Ecto.Migrator.up(Repo, 20_261_104_090_000, AddClassificationLifecycle,
               log: false,
               migration_lock: false
             )

    assert %{selected: false, origin: :manual, lock_version: 7, probability: nil} =
             Repo.reload!(original)

    assert Repo.reload!(doc).generation == 0
  end
end
