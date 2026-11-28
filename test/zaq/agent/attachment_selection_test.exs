defmodule Zaq.Agent.AttachmentSelectionTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Request.Handle
  alias Jido.AI.Runtime.Event
  alias Zaq.Agent.{Factory, OpaqueAliases, StreamEvents}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Incoming

  defmodule Status do
    def broadcast(incoming, _stage, _text, _router, _opts), do: incoming
  end

  setup do
    scope = Ecto.UUID.generate()
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
    {:ok, scope: scope}
  end

  defp event(kind, id \\ nil, data \\ %{}, request \\ "request") do
    Event.new(%{
      kind: kind,
      request_id: request,
      run_id: request,
      seq: 1,
      iteration: 1,
      tool_call_id: id,
      tool_name: "attach_documents",
      data: data
    })
  end

  defp file(id) do
    {:ok, file} =
      Provenance.seal(%Record{
        id: id,
        kind: :file,
        permissions: [],
        attributes: %{provider_record_id: id}
      })

    file
  end

  defp completed(id, operation, records, scope) do
    call = %{id: id, name: "attach_documents", action_module: AttachDocuments}

    {:ok, result} =
      Factory.after_tool_call(
        call,
        {:ok, %{operation: operation, records: records}, []},
        %{opaque_alias_scope: scope, request_id: "request"}
      )

    event(:tool_completed, id, %{result: result})
  end

  defp consume(events, scope) do
    StreamEvents.consume(
      events,
      %Incoming{message_id: "request", provider: :web, content: "Select", channel_id: "channel"},
      opaque_alias_scope: scope,
      request: %Handle{id: "request", server: self(), query: "Select"},
      status_module: Status
    )
  end

  test "declaration order wins over completion order and duplicate completions", %{scope: scope} do
    a = file("a")
    b = file("b")
    add = completed("add", "add", [a, b], scope)
    remove = completed("remove", "remove", [a], scope)

    events = [
      event(:tool_started, "add"),
      event(:tool_started, "remove"),
      remove,
      add,
      add,
      event(:request_completed, nil, %{result: "Done", termination_reason: :final_answer})
    ]

    assert {:ok, result} = consume(events, scope)
    assert result.attachments == [b]
    evidence = Jason.encode!(Map.take(result, [:trace, :tool_calls]))
    refute evidence =~ a.provenance_ref
    refute evidence =~ "attachment_instruction"
    assert length(result.tool_calls) == 2
  end

  test "only resolved current native invocations can select", %{scope: scope} do
    good = completed("good", "add", [file("good")], scope)
    foreign = %{completed("foreign", "add", [file("foreign")], scope) | request_id: "other"}
    nested = completed("nested", "replace", [], scope)

    nested = %{
      nested
      | data:
          Map.merge(nested.data, %{
            origin: "zaq_action",
            parent_id: "good",
            invocation_path: ["good", "nested"]
          })
    }

    events = [
      completed("unknown", "add", [file("unknown")], scope),
      event(:tool_started, "foreign", %{}, "other"),
      foreign,
      event(:tool_started, "good"),
      good,
      nested,
      event(:tool_completed, "failure", %{result: {:error, :denied, []}}),
      event(:request_completed, nil, %{result: "Done"})
    ]

    assert {:ok, result} = consume(events, scope)
    assert Enum.map(result.attachments, & &1.id) == ["good"]
  end

  test "failed, cancelled, exhausted and handoff requests publish no files", %{scope: scope} do
    selected = [event(:tool_started, "one"), completed("one", "add", [file("one")], scope)]

    for terminal <- [
          event(:request_failed, nil, %{error: :timeout}),
          event(:request_cancelled),
          event(:request_completed, nil, %{termination_reason: :handoff}),
          event(:request_completed, nil, %{termination_reason: :max_iterations})
        ] do
      result =
        case consume(selected ++ [terminal], scope) do
          {:ok, result} -> result
          {:error, _, result} -> result
        end

      assert result.attachments == []
    end

    assert {:ok, exhausted} = consume(selected, scope)
    assert exhausted.attachments == []
    assert {:ok, next} = consume([event(:request_completed, nil, %{result: "Text"})], scope)
    assert next.attachments == []
  end

  test "malformed completion and failed retry preserve earlier successful selection", %{
    scope: scope
  } do
    good = file("good")

    events = [
      event(:tool_started, "good"),
      completed("good", "add", [good], scope),
      event(:tool_started, "bad"),
      event(:tool_completed, "bad", %{
        result: {:ok, %{operation: "replace", records: ["malformed"]}, []}
      }),
      event(:tool_started, "denied"),
      event(:tool_completed, "denied", %{result: {:error, :denied, []}}),
      event(:tool_started, "failed-outcome"),
      Map.update!(
        completed("failed-outcome", "replace", [], scope),
        :data,
        &Map.put(&1, :outcome, "failed")
      ),
      event(:request_completed, nil, %{result: "Done"})
    ]

    assert {:ok, result} = consume(events, scope)
    assert result.attachments == [good]
  end

  test "foreign terminals, late events and same-request retry do not clear valid selection", %{
    scope: scope
  } do
    b = file("b")

    events = [
      event(:tool_started, "failed"),
      event(:tool_completed, "failed", %{result: {:error, :denied, []}}),
      event(:request_failed, nil, %{error: :foreign}, "other"),
      event(:tool_started, "retry"),
      completed("retry", "add", [b], scope),
      event(:request_completed, nil, %{result: "Done"}),
      event(:tool_started, "late"),
      completed("late", "replace", [], scope)
    ]

    assert {:ok, result} = consume(events, scope)
    assert result.attachments == [b]
    assert Enum.map(result.tool_calls, & &1["id"]) == ["failed", "retry"]
  end

  test "clear applies exactly and wrong-scope aliases leave the selection intact", %{scope: scope} do
    a = file("a")
    other = Ecto.UUID.generate()
    on_exit(fn -> OpaqueAliases.clear_scope(other) end)

    events = [
      event(:tool_started, "add"),
      completed("add", "add", [a], scope),
      event(:tool_started, "wrong"),
      completed("wrong", "add", [file("b")], other),
      event(:request_completed, nil, %{result: "Done"})
    ]

    assert {:ok, result} = consume(events, scope)
    assert result.attachments == [a]

    events =
      Enum.drop(events, -1) ++
        [
          event(:tool_started, "clear"),
          completed("clear", "replace", [], scope),
          event(:request_completed)
        ]

    assert {:ok, result} = consume(events, scope)
    assert result.attachments == []
  end
end
