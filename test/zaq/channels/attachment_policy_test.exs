defmodule Zaq.Channels.AttachmentPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.{DeliveryExecutor, DeliveryFiles, FileRequirements}
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.TestSupport.DeliveryTestOwner

  defmodule PlanningBridge do
    def file_requirements(_outgoing, connection) do
      send(self(), :requirements_requested)
      {:ok, Map.fetch!(connection, :requirements)}
    end

    def prepare_upload_request(files, connection) do
      size = 20 + Enum.sum(Enum.map(files, & &1.size))

      if size <= connection.requirements.max_upload_request_bytes,
        do: {:ok, %{encoded_bytes: size, request: Enum.map(files, & &1.attachment_index)}},
        else: {:error, :upload_request_too_large}
    end

    def prepare_delivery_message(outgoing, files, _connection) do
      payload = outgoing.body <> Enum.map_join(files, & &1.content)
      {:ok, %{encoded_bytes: byte_size(payload), message: payload}}
    end
  end

  test "ordinary text bypasses every planning callback and retains a nil plan" do
    outgoing = outgoing()
    assert {:ok, ^outgoing} = DeliveryFiles.build_plan(outgoing, PlanningBridge, %{})
    assert outgoing.delivery_plan == nil
    refute_received :requirements_requested
  end

  test "one message can require two explicitly prepared upload requests" do
    records = Enum.map(0..3, &file("file-#{&1}", "1234567890"))

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               planning_connection(10, 40)
             )

    assert [%{file_refs: [0, 1, 2, 3]}] = planned.delivery_plan.groups

    assert Enum.map(planned.delivery_plan.steps, &{&1.operation, &1.file_refs}) ==
             [{:upload, [0, 1]}, {:upload, [2, 3]}, {:send, [0, 1, 2, 3]}]

    assert List.last(planned.delivery_plan.steps).depends_on == [{:upload, 0, 0}, {:upload, 0, 1}]
    refute inspect(planned.delivery_plan) =~ "1234567890"
  end

  test "a non-applicable upload ceiling preserves exact preparation and other group limits" do
    records = Enum.map(0..3, &file("file-#{&1}", "1234567890"))
    connection = planning_connection(3, :not_applicable)

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery_plan.groups, & &1.file_refs) == [[0, 1, 2], [3]]
    uploads = Enum.filter(planned.delivery_plan.steps, &(&1.operation == :upload))
    assert Enum.map(uploads, & &1.file_refs) == [[0, 1, 2], [3]]
    assert Enum.map(uploads, & &1.prepared.encoded_bytes) == [50, 30]
    assert planned.delivery_plan.preparation_failures == []

    connection = put_in(connection.requirements.max_attachment_bytes_per_message, 20)

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery_plan.groups, & &1.file_refs) == [[0, 1], [2, 3]]
  end

  test "fifteen ordered files become ten plus five and an existing message is edited" do
    records = Enum.map(0..14, &file("file-#{&1}", "bytes"))
    outgoing = %{outgoing() | attachments: records, metadata: %{message_id: "streamed"}}

    assert {:ok, planned} =
             DeliveryFiles.build_plan(outgoing, PlanningBridge, planning_connection(10, 1000))

    assert Enum.map(planned.delivery_plan.groups, &length(&1.file_refs)) == [10, 5]
    assert [edit, send] = Enum.reject(planned.delivery_plan.steps, &(&1.operation == :upload))
    assert edit.operation == :edit
    assert edit.message_ref == {:existing, "streamed"}
    assert send.operation == :send
  end

  test "combined message grouping uses exact body overhead as well as attachment byte limits" do
    records = Enum.map(0..2, &file("file-#{&1}", "12345678"))
    connection = planning_connection(10, 1000)

    requirements = %{
      connection.requirements
      | transfer_mode: :send_with_files,
        max_encoded_message_bytes: 22,
        max_upload_request_bytes: :not_applicable
    }

    connection = %{connection | requirements: requirements}

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery_plan.groups, & &1.file_refs) == [[0, 1], [2]]
    assert Enum.map(planned.delivery_plan.groups, & &1.prepared.encoded_bytes) == [22, 14]

    connection = put_in(connection.requirements.max_attachment_bytes_per_message, 12)

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery_plan.groups, & &1.file_refs) == [[0], [1], [2]]
  end

  property "the first surviving upload group edits the streamed message without renumbering" do
    check all(omitted_count <- integer(1..5)) do
      records =
        List.duplicate(file("too-large", String.duplicate("x", 21)), omitted_count) ++
          [file("valid", "ok"), file("later", "ok")]

      outgoing = %{outgoing() | attachments: records, metadata: %{message_id: "streamed"}}

      assert {:ok, planned} =
               DeliveryFiles.build_plan(outgoing, PlanningBridge, planning_connection(1, 40))

      plan = planned.delivery_plan
      assert Enum.map(plan.groups, & &1.id) == [omitted_count, omitted_count + 1]

      assert Enum.map(plan.preparation_failures, & &1.attachment_index) ==
               Enum.to_list(0..(omitted_count - 1))

      assert [edit, send] = Enum.reject(plan.steps, &(&1.operation == :upload))
      assert edit.id == {:edit, omitted_count}
      assert edit.message_ref == {:existing, "streamed"}
      assert edit.file_refs == [omitted_count]
      assert send.id == {:send, omitted_count + 1}
    end
  end

  test "a partially omitted first group keeps its edit and a missing streamed ID creates a post" do
    records = [
      file("too-large", String.duplicate("x", 21)),
      file("valid", "ok"),
      file("later", "ok")
    ]

    for {metadata, operation, target} <- [
          {%{message_id: "streamed"}, :edit, {:existing, "streamed"}},
          {%{}, :send, nil}
        ] do
      outgoing = %{outgoing() | attachments: records, metadata: metadata}

      assert {:ok, planned} =
               DeliveryFiles.build_plan(outgoing, PlanningBridge, planning_connection(2, 40))

      assert [%{id: 0, file_refs: [1]}, %{id: 1, file_refs: [2]}] = planned.delivery_plan.groups

      assert [first, second] =
               Enum.reject(planned.delivery_plan.steps, &(&1.operation == :upload))

      assert first.operation == operation
      assert first.message_ref == target
      assert second.operation == :send
      assert [%{attachment_index: 0}] = planned.delivery_plan.preparation_failures
    end
  end

  test "all upload groups omitted retain one text fallback and all failed indices" do
    outgoing = %{
      outgoing()
      | attachments: List.duplicate(file("too-large", String.duplicate("x", 21)), 3)
    }

    assert {:ok, planned} =
             DeliveryFiles.build_plan(outgoing, PlanningBridge, planning_connection(1, 40))

    assert [%{file_refs: [], body: "Answer"}] = planned.delivery_plan.groups
    assert [%{operation: :send, file_refs: []}] = planned.delivery_plan.steps

    assert Enum.map(planned.delivery_plan.preparation_failures, & &1.attachment_index) == [
             0,
             1,
             2
           ]
  end

  test "an omitted leading group without a streamed ID creates the first surviving post" do
    outgoing = %{
      outgoing()
      | attachments: [file("too-large", String.duplicate("x", 21)), file("valid", "ok")]
    }

    assert {:ok, planned} =
             DeliveryFiles.build_plan(outgoing, PlanningBridge, planning_connection(1, 40))

    assert [%{id: 1, file_refs: [1]}] = planned.delivery_plan.groups

    assert [%{id: {:send, 1}, message_ref: nil, file_refs: [1]}] =
             Enum.reject(planned.delivery_plan.steps, &(&1.operation == :upload))

    assert [%{attachment_index: 0}] = planned.delivery_plan.preparation_failures
  end

  test "continue retains five of six files while stop prevents execution" do
    records =
      Enum.map(0..5, fn index ->
        if index == 2, do: file("bad", nil), else: file("file-#{index}", "ok")
      end)

    connection = planning_connection(10, 1000)

    assert {:ok, planned} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: records},
               PlanningBridge,
               connection
             )

    assert [%{file_refs: [0, 1, 3, 4, 5]}] = planned.delivery_plan.groups

    assert [%{attachment_index: 2, stage: :preparation}] =
             planned.delivery_plan.preparation_failures

    assert {:error, %{delivery: :not_sent}} =
             DeliveryFiles.build_plan(%{outgoing() | attachments: records}, PlanningBridge, %{
               connection
               | attachment_failure_policy: :abort
             })
  end

  test "request limit accepts exact bytes and omits an individual file one byte over" do
    for {size, expected} <- [{20, [0]}, {21, []}] do
      record = file("sized", String.duplicate("a", size))

      assert {:ok, planned} =
               DeliveryFiles.build_plan(
                 %{outgoing() | attachments: [record]},
                 PlanningBridge,
                 planning_connection(10, 40)
               )

      assert Enum.flat_map(planned.delivery_plan.groups, & &1.file_refs) == expected
      assert length(planned.delivery_plan.preparation_failures) == if(size == 20, do: 0, else: 1)
    end
  end

  test "unresolved limits fail before acquisition and selection failure enters shared policy" do
    connection = planning_connection(10, 1000)
    connection = put_in(connection.requirements.max_file_bytes, :unresolved)

    assert {:error, %{stage: :configuration}} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: [file("lazy", nil)]},
               PlanningBridge,
               %{connection | attachment_failure_policy: :abort}
             )

    selected = %{outgoing() | attachment_error: :invalid_attachment_selection}

    assert {:ok, planned} =
             DeliveryFiles.build_plan(selected, PlanningBridge, %{
               attachment_failure_policy: :continue
             })

    assert [%{stage: :selection}] = planned.delivery_plan.preparation_failures
    assert [%{file_refs: []}] = planned.delivery_plan.groups
    assert hd(planned.delivery_plan.groups).body =~ "The requested files could not be attached."

    assert {:error, %{stage: :selection}} =
             DeliveryFiles.build_plan(selected, PlanningBridge, %{
               attachment_failure_policy: :abort
             })
  end

  test "malformed attachment lists and oversized planned fallback text are rejected" do
    assert {:error, %{reason: :invalid_attachments}} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: nil},
               PlanningBridge,
               planning_connection(10, 1000)
             )

    connection = planning_connection(10, 1000)

    requirements = %{
      connection.requirements
      | transfer_mode: :send_with_files,
        max_encoded_message_bytes: 5,
        max_upload_request_bytes: :not_applicable
    }

    assert {:error, %{delivery: :not_sent}} =
             DeliveryFiles.build_plan(
               %{outgoing() | attachments: [file("bad", nil)]},
               PlanningBridge,
               %{connection | requirements: requirements}
             )
  end

  property "planning partitions original indices once in stable bounded groups" do
    check all(
            contents <- list_of(binary(max_length: 80), min_length: 1, max_length: 25),
            count <- integer(1..10)
          ) do
      records =
        contents
        |> Enum.with_index()
        |> Enum.map(fn {bytes, index} -> file("file-#{index}", bytes) end)

      assert {:ok, planned} =
               DeliveryFiles.build_plan(
                 %{outgoing() | attachments: records},
                 PlanningBridge,
                 planning_connection(count, 200)
               )

      plan = planned.delivery_plan
      assert Enum.flat_map(plan.groups, & &1.file_refs) == Enum.to_list(0..(length(contents) - 1))
      assert Enum.all?(plan.groups, &(length(&1.file_refs) <= count))
      assert Enum.map(Enum.sort(plan.files), fn {_index, file} -> file.content end) == contents

      assert Enum.all?(
               Enum.filter(plan.steps, &(&1.operation == :upload)),
               &(&1.prepared.encoded_bytes <= 200)
             )
    end
  end

  defp planning_connection(count, request_bytes) do
    %{
      attachment_failure_policy: :continue,
      requirements: %FileRequirements{
        transfer_mode: :upload_then_publish,
        max_files_per_message: count,
        max_file_bytes: 1000,
        max_attachment_bytes_per_message: :not_applicable,
        max_encoded_message_bytes: :not_applicable,
        max_upload_request_bytes: request_bytes,
        supports_threads: true,
        supports_attachment_edits: true
      }
    }
  end

  defmodule ConnectionResolver do
    def fetch_connection_details_for_config(config), do: config
  end

  defmodule LegacyTextBridge do
    def send_reply(outgoing, connection) do
      send(DeliveryTestOwner.pid(), {:legacy_notice, outgoing})
      Map.get(connection, :response, {:ok, %{confirmation: :confirmed, message_id: "notice-id"}})
    end

    def delivery_completed(_outgoing, _report, _connection), do: send(self(), :notice_callback)
  end

  test "selection fallback uses shared execution and preserves the canonical answer without callbacks" do
    outgoing = %{
      outgoing()
      | attachment_error: :invalid_attachment_selection,
        metadata: %{on_reply: "private callback", html_body: "original HTML"}
    }

    assert {:ok, planned} =
             DeliveryFiles.build_plan(outgoing, LegacyTextBridge, %{
               attachment_failure_policy: :continue
             })

    assert {:ok,
            %{
              confirmation: :partial,
              messages: [%{body: "Answer", delivered_attachment_indices: []}]
            }} =
             DeliveryExecutor.execute(planned, LegacyTextBridge, %{})

    assert_receive {:legacy_notice, notice}
    assert notice.body == "Answer\n\nThe requested files could not be attached."
    assert notice.attachment_error == nil
    assert notice.metadata == %{}
    refute_received :notice_callback
    refute_received {:legacy_notice, _}
  end

  property "Jido outbound resolution preserves connection details and resolves the connector policy" do
    check all(
            {setting, expected} <-
              member_of([
                {false, :abort},
                {"false", :abort},
                {true, :continue},
                {"true", :continue},
                {nil, :continue}
              ]),
            token <- string(:alphanumeric, min_length: 1),
            max_runs: 25
          ) do
      connection = %{
        url: "https://chat.example.test",
        token: token,
        settings: %{"send_on_file_failure" => setting},
        adapter_opts: [max_file_size: 1024]
      }

      assert {:ok, resolved} =
               JidoChatBridge.fetch_connection_details_for_config(connection,
                 outgoing: outgoing(),
                 connection_resolver: ConnectionResolver
               )

      assert resolved.attachment_failure_policy == expected
      assert Map.delete(resolved, :attachment_failure_policy) == connection
    end
  end

  test "Jido outbound resolution defaults to continue and retains an explicit resolved policy" do
    assert {:ok, %{attachment_failure_policy: :continue}} =
             JidoChatBridge.fetch_connection_details_for_config(%{},
               outgoing: outgoing(),
               connection_resolver: ConnectionResolver
             )

    connection = %{attachment_failure_policy: :abort, settings: %{"send_on_file_failure" => true}}

    assert {:ok, ^connection} =
             JidoChatBridge.fetch_connection_details_for_config(connection,
               outgoing: outgoing(),
               connection_resolver: ConnectionResolver
             )
  end

  test "continue prepares usable files and records safe failures in input order" do
    files = [
      file("first", "one"),
      file("bad", "%%%", %{"encoding" => "base64"}),
      file("last", "two")
    ]

    assert {:ok, prepared, [failure]} =
             DeliveryFiles.prepare(files, %{}, attachment_failure_policy: :continue)

    assert Enum.map(prepared, &{&1.attachment_index, &1.content}) == [{0, "one"}, {2, "two"}]
    assert failure.attachment_index == 1
    assert failure.stage == :preparation
    assert failure.delivery == :not_sent
    refute inspect(failure) =~ "%%%"
  end

  test "invalid explicit preparation policy fails before acquiring files" do
    assert {:error, {:invalid_attachment_failure_policy, :invalid}} =
             DeliveryFiles.prepare([file("bad", nil)], %{}, attachment_failure_policy: :invalid)
  end

  test "continue returns a known empty file selection after all preparations fail" do
    assert {:ok, [], [%{attachment_index: 0}]} =
             DeliveryFiles.prepare([file("bad", nil)], %{}, attachment_failure_policy: :continue)
  end

  test "abort preserves the original preparation error and absent policy remains compatible" do
    records = [file("ok", "ready"), file("bad", "%%%", %{"encoding" => "base64"})]

    assert {:error, :invalid_attachment_base64} =
             DeliveryFiles.prepare(records, %{}, attachment_failure_policy: :abort)

    assert {:error, :invalid_attachment_base64} = DeliveryFiles.prepare(records, %{})
  end

  property "continue preserves every usable byte, order and original index around failed files" do
    check all(bytes <- list_of(binary(max_length: 256), max_length: 10)) do
      records =
        Enum.flat_map(Enum.with_index(bytes), fn {content, index} ->
          [file("#{index}", content), file("invalid-#{index}", nil)]
        end)

      assert {:ok, prepared, failures} =
               DeliveryFiles.prepare(records, %{}, attachment_failure_policy: :continue)

      assert Enum.map(prepared, & &1.content) == bytes

      assert Enum.map(prepared, & &1.attachment_index) ==
               Enum.map(Enum.with_index(bytes), fn {_, index} -> index * 2 end)

      assert length(failures) == length(bytes)
    end
  end

  defp outgoing,
    do: %Outgoing{body: "Answer", channel_id: "room", provider: :mattermost}

  defp file(id, content, attributes \\ %{}),
    do: %Record{id: id, kind: :file, name: "#{id}.txt", content: content, attributes: attributes}
end
