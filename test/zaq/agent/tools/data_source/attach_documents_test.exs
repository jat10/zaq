defmodule Zaq.Agent.Tools.DataSource.AttachDocumentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

  defp context do
    %{
      actor: %Person{id: 1, email: "reader@example.com", channels: []},
      request_id: "request",
      state: %{requests: %{"request" => %{status: :pending}}}
    }
  end

  defp record(id, claims \\ %{}) do
    permission = %Record{
      id: "grant",
      kind: :permission,
      attributes: %{
        "principal_type" => "email",
        "principal_key" => "reader@example.com",
        "access_rights" => ["read"]
      }
    }

    {:ok, record} =
      Provenance.seal(%Record{id: id, kind: :file, permissions: [permission]}, claims)

    record
  end

  test "validated selection is metadata only and requires explicit tool enablement" do
    file = %{record("a") | content: "untrusted inline bytes", size: 999_999_999}

    assert {:ok, %{operation: "add", records: [selected]}} =
             ActionContract.execute(
               AttachDocuments,
               %{operation: "add", records: [file]},
               context()
             )

    assert selected.id == "a"
    assert selected.content == nil
    assert {:ok, [AttachDocuments]} = Registry.resolve_modules(["data_source.attach_document"])
    assert {:ok, []} = Registry.resolve_modules([])
  end

  test "standalone, inactive, missing actor and nonliteral bypass fail closed" do
    params = %{operation: "replace", records: []}

    for ctx <- [
          %{},
          Map.put(context(), :state, %{requests: %{}}),
          put_in(context(), [:state, :requests, "request", :status], :completed),
          Map.put(context(), :actor, nil),
          context() |> Map.put(:actor, nil) |> Map.put(:person_id, 1),
          context() |> Map.put(:actor, nil) |> Map.put(:skip_permissions, "true")
        ] do
      assert {:error, _} = ActionContract.execute(AttachDocuments, params, ctx)
    end

    assert {:ok, %{records: []}} = ActionContract.execute(AttachDocuments, params, context())
  end

  test "a denied batch fails atomically and bypass never accepts forged or nonfile records" do
    denied = record("denied")
    {:ok, denied} = Provenance.seal(%{denied | permissions: []})
    params = %{operation: "add", records: [record("allowed"), denied]}
    assert {:error, _} = ActionContract.execute(AttachDocuments, params, context())

    {:ok, folder} = Provenance.seal(%Record{id: "folder", kind: :folder, permissions: []})

    for file <- [%{record("a") | id: "forged"}, folder, record("")] do
      assert {:error, _} =
               ActionContract.execute(
                 AttachDocuments,
                 %{operation: "add", records: [file]},
                 Map.put(context(), :skip_permissions, true)
               )
    end
  end

  test "permission bypass must be literal and never comes from model parameters" do
    ctx = %{context() | actor: %Person{id: 2, email: "other@example.com", channels: []}}
    params = %{operation: "add", records: [record("a")]}
    assert {:error, _} = ActionContract.execute(AttachDocuments, params, ctx)

    assert {:error, _} =
             ActionContract.execute(
               AttachDocuments,
               params,
               Map.put(ctx, :skip_permissions, "true")
             )

    assert {:error, _} =
             ActionContract.execute(
               AttachDocuments,
               Map.put(params, :skip_permissions, true),
               ctx
             )

    assert {:ok, %{records: [_]}} =
             ActionContract.execute(
               AttachDocuments,
               params,
               Map.put(ctx, :skip_permissions, true)
             )
  end

  property "ordered add/remove/replace obey source identity across signatures and configurations" do
    check all(
            instructions <-
              list_of(
                tuple(
                  {member_of(~w(add remove replace)),
                   list_of(member_of(~w(a b c)), max_length: 6)}
                ),
                max_length: 20
              )
          ) do
      files = Map.new(~w(a b c), &{&1, record(&1)})

      {selected, expected} =
        Enum.reduce(instructions, {[], []}, fn {operation, ids}, {selected, expected} ->
          records = Enum.map(ids, &Map.fetch!(files, &1))

          {:ok, next} =
            AttachDocuments.reduce_selection(selected, %{operation: operation, records: records})

          expected =
            case operation do
              "add" -> Enum.uniq(expected ++ ids)
              "remove" -> expected -- ids
              "replace" -> Enum.uniq(ids)
            end

          {next, expected}
        end)

      assert Enum.map(selected, & &1.id) == expected
    end
  end

  test "same provider id on distinct configs never collapses, refreshed signatures do" do
    a = record("a", %{"provider" => "disk", "config_id" => 1})
    b = record("a", %{"provider" => "disk", "config_id" => 2})

    assert {:ok, [^a, ^b]} =
             AttachDocuments.reduce_selection([], %{operation: "add", records: [a, b, a]})

    assert {:ok, [^b]} =
             AttachDocuments.reduce_selection([a, b], %{operation: "remove", records: [a]})

    assert {:ok, []} =
             AttachDocuments.reduce_selection([a, b], %{operation: "replace", records: []})
  end
end
