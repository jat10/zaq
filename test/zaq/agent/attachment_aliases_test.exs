defmodule Zaq.Agent.AttachmentAliasesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.ToolResult
  alias Zaq.Agent.{Factory, OpaqueAliases}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

  test "private output expands only schema-declared aliases in the logical server scope" do
    scope = Ecto.UUID.generate()
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
    context = %{opaque_alias_scope: scope, request_id: "request"}
    {:ok, file} = Provenance.seal(%Record{id: "file", kind: :file, permissions: []})
    call = %{id: "call", name: "attach_documents", action_module: AttachDocuments}
    output = %{operation: "add", records: [file]}

    assert {:ok, {:ok, aliased, []}} = Factory.after_tool_call(call, {:ok, output, []}, context)

    assert aliased.records
           |> hd()
           |> Map.fetch!("provenance_ref")
           |> String.starts_with?("prov_")

    assert {:ok, {:ok, expanded, []}} =
             OpaqueAliases.expand_tool_result(call, {:ok, aliased, []}, context)

    assert {:ok, %{records: [%Record{provenance_ref: ref}]}} =
             AttachDocuments.validate_output(expanded)

    assert ref == file.provenance_ref

    wrapped = %ToolResult{output: aliased, metadata: %{note: "preserved"}}

    assert {:ok, {:ok, wrapper, [:effect]}} =
             OpaqueAliases.expand_tool_result(call, {:ok, wrapped, [:effect]}, context)

    assert wrapper.output == expanded
    assert wrapper.metadata == wrapped.metadata

    for other <- [%{}, %{opaque_alias_scope: Ecto.UUID.generate()}] do
      assert {:error, _} = OpaqueAliases.expand_tool_result(call, {:ok, aliased, []}, other)
    end

    assert {:ok, canonical} = OpaqueAliases.expand_tool_result(call, {:ok, output, []}, context)
    assert canonical == {:ok, output, []}
    :ok = OpaqueAliases.clear_scope(scope)
    assert {:error, _} = OpaqueAliases.expand_tool_result(call, {:ok, aliased, []}, context)
  end

  test "input expansion and validation keep unknown aliases and tampering out" do
    context = %{opaque_alias_scope: Ecto.UUID.generate()}
    on_exit(fn -> OpaqueAliases.clear_scope(context.opaque_alias_scope) end)
    {:ok, file} = Provenance.seal(%Record{id: "file", kind: :file, permissions: []})
    call = %{id: "call", name: "attach_documents", action_module: AttachDocuments}

    assert {:ok, {:ok, output, []}} =
             OpaqueAliases.alias_tool_result(
               call,
               {:ok, %{operation: "add", records: [file]}, []},
               context
             )

    assert {:ok, expanded} = Factory.before_tool_call(Map.put(call, :arguments, output), context)
    assert {:ok, _} = AttachDocuments.validate_params(expanded.arguments)

    tampered = Enum.map(expanded.arguments.records, &Map.put(&1, :id, "tampered"))

    assert {:error, _} =
             AttachDocuments.validate_params(%{expanded.arguments | records: tampered})

    unknown = Enum.map(output.records, &Map.put(&1, :provenance_ref, "prov_unknown"))

    assert {:error, _} =
             Factory.before_tool_call(
               Map.put(call, :arguments, %{output | records: unknown}),
               context
             )
  end
end
