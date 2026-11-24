defmodule Zaq.Channels.AttachmentPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Attachments, Executor, Plan}
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  defmodule PlanningBridge do
    alias Zaq.ConnectorConfig.Settings

    def existing_message(outgoing, connection) do
      send(connection.test_pid, :existing_message_requested)
      if connection.requirements.supports_attachment_edits, do: outgoing.metadata[:message_id]
    end

    def transport_requirements(_outgoing, connection) do
      send(connection.test_pid, :requirements_requested)

      requirements = %{
        connection.requirements
        | failure_policy: Settings.attachment_failure_policy(connection)
      }

      case TransportRequirements.validate(requirements) do
        :ok -> {:ok, requirements}
        {:error, error} -> {:error, error, requirements.failure_policy}
      end
    end

    def prepare_upload_request(attachments, connection) do
      send(connection.test_pid, {:prepared_upload, Enum.map(attachments, & &1.attachment_index)})
      if connection[:raise_preparation], do: raise("private preparation bytes")

      {:ok,
       %{encoded_bytes: 20 + Enum.sum(Enum.map(attachments, & &1.size)), request: attachments}}
    end

    def prepare_delivery_message(outgoing, attachments, connection) do
      send(connection.test_pid, {:prepared_message, Enum.map(attachments, & &1.attachment_index)})
      payload = outgoing.body <> Enum.map_join(attachments, & &1.content)
      {:ok, %{encoded_bytes: byte_size(payload), message: payload}}
    end

    def execute_delivery_step(step, inputs, connection) do
      send(connection.test_pid, {:operation, step, inputs})

      if step.operation == :upload do
        {:ok,
         %{
           uploaded_attachments:
             Enum.map(step.attachment_refs, &%{id: "upload-#{&1}", attachment_index: &1})
         }}
      else
        {:ok,
         %{confirmation: :confirmed, message_id: "message-#{step.group_id}", action: :created}}
      end
    end
  end

  test "ordinary text including a selection error bypasses every planning callback under both policies" do
    for policy <- [:continue, :abort], error <- [nil, :invalid_attachment_selection] do
      outgoing = put_in(outgoing().delivery.error, error)

      assert {:ok, ^outgoing} =
               Attachments.build_plan(outgoing, PlanningBridge, %{
                 attachment_failure_policy: policy
               })

      assert outgoing.delivery.plan == nil
      assert outgoing.delivery.error == error
    end

    refute_received :requirements_requested
    refute_received {:prepared_upload, _}
    refute_received {:prepared_message, _}
  end

  test "planning uses declared metadata without decoding content or preparing provider requests" do
    records = [
      %Record{
        id: "lazy",
        kind: :file,
        size: 5,
        content: nil,
        materialization_handle: "not-redeemed"
      },
      file("invalid-base64", "%%%", %{"encoding" => "base64"})
    ]

    outgoing = put_in(outgoing().delivery.attachments, records)

    assert {:ok, planned} =
             Attachments.build_plan(
               outgoing,
               PlanningBridge,
               planning_connection(10, 1000)
             )

    assert planned.delivery.attachments == records
    refute Map.has_key?(planned.delivery.plan, :attachments)
    refute Map.has_key?(planned.delivery.plan, :files)
    assert [%{attachment_refs: [0, 1]}] = planned.delivery.plan.groups
    refute_received {:prepared_upload, _}
    refute_received {:prepared_message, _}
  end

  test "fifteen ordered attachments become ten plus five and reuse the streamed message" do
    records = Enum.map(0..14, &file("attachment-#{&1}", "bytes"))

    outgoing = %{
      outgoing()
      | delivery: %Outgoing.Delivery{attachments: records},
        metadata: %{message_id: "streamed"}
    }

    assert {:ok, planned} =
             Attachments.build_plan(
               outgoing,
               PlanningBridge,
               planning_connection(10, 1000)
             )

    assert Enum.map(planned.delivery.plan.groups, &length(&1.attachment_refs)) == [10, 5]

    assert [%{operation: :edit, message_ref: {:existing, "streamed"}}, %{operation: :send}] =
             Enum.reject(planned.delivery.plan.steps, &(&1.operation == :upload))
  end

  test "metadata assigns upload batches independently from message groups" do
    records = Enum.map(0..3, &file("attachment-#{&1}", "1234567890"))

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               planning_connection(10, 20)
             )

    assert [%{attachment_refs: [0, 1, 2, 3]}] = planned.delivery.plan.groups

    assert Enum.map(planned.delivery.plan.steps, &{&1.operation, &1.attachment_refs}) == [
             {:upload, [0, 1]},
             {:upload, [2, 3]},
             {:send, [0, 1, 2, 3]}
           ]

    assert List.last(planned.delivery.plan.steps).depends_on == [{:upload, 0, 0}, {:upload, 0, 1}]
  end

  test "exact multipart overhead is checked in execution without regrouping" do
    records = Enum.map(0..3, &file("attachment-#{&1}", "1234567890"))
    connection = planning_connection(10, 40, :abort)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               connection
             )

    original_plan = planned.delivery.plan

    assert {:error, %{stage: :preparation, delivery: :not_sent}} =
             Executor.execute(planned, PlanningBridge, connection)

    assert planned.delivery.plan == original_plan
    assert planned.delivery.attachments == records
    refute_received {:operation, _, _}
  end

  test "preparation exceptions fail safely before transport under stop" do
    connection = Map.put(planning_connection(10, 1000, :abort), :raise_preparation, true)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, [file("one", "bytes")]),
               PlanningBridge,
               connection
             )

    assert {:error, error} = Executor.execute(planned, PlanningBridge, connection)
    assert error.stage == :preparation
    assert error.delivery == :not_sent
    refute inspect(error) =~ "private preparation bytes"
    refute_received {:operation, _, _}
  end

  test "non-applicable upload ceilings still prepare exact requests and preserve other bounds" do
    connection = planning_connection(3, :not_applicable)
    records = Enum.map(0..3, &file("attachment-#{&1}", "1234567890"))

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery.plan.groups, & &1.attachment_refs) == [[0, 1, 2], [3]]
    assert {:ok, _} = Executor.execute(planned, PlanningBridge, connection)
    assert_received {:prepared_upload, [0, 1, 2]}
    assert_received {:prepared_upload, [3]}
    connection = put_in(connection.requirements.max_attachment_bytes_per_message, 20)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               connection
             )

    assert Enum.map(planned.delivery.plan.groups, & &1.attachment_refs) == [[0, 1], [2, 3]]
  end

  test "exact encoded message limits accept equality and reject one byte over before effects" do
    for {ceiling, expected} <- [{14, :ok}, {13, :error}] do
      connection = planning_connection(10, :not_applicable, :abort)

      connection = %{
        connection
        | requirements: %{
            connection.requirements
            | transfer_mode: :send_with_attachments,
              max_encoded_message_bytes: ceiling
          }
      }

      records = [file("attachment", "12345678")]

      assert {:ok, planned} =
               Attachments.build_plan(
                 put_in(outgoing().delivery.attachments, records),
                 PlanningBridge,
                 connection
               )

      assert elem(Executor.execute(planned, PlanningBridge, connection), 0) == expected

      if expected == :ok,
        do: assert_received({:operation, _, _}),
        else: refute_received({:operation, _, _})
    end
  end

  test "continue retains five of six attachments with original failure index and stop publishes nothing" do
    records =
      Enum.map(0..5, fn index ->
        file("attachment-#{index}", if(index == 2, do: "%%%", else: "b2s="), %{
          "encoding" => "base64"
        })
      end)

    for policy <- [:continue, :abort] do
      connection = planning_connection(10, 1000, policy)

      assert {:ok, planned} =
               Attachments.build_plan(
                 put_in(outgoing().delivery.attachments, records),
                 PlanningBridge,
                 connection
               )

      assert planned.delivery.plan.preparation_failures == []

      case policy do
        :abort ->
          assert {:error, %{stage: :preparation}} =
                   Executor.execute(planned, PlanningBridge, connection)

          refute_received {:operation, _, _}

        :continue ->
          assert {:ok, %{confirmation: :partial, failed_attachments: [%{attachment_index: 2}]}} =
                   Executor.execute(planned, PlanningBridge, connection)

          assert_received {:operation, %{operation: :upload, attachment_refs: [0, 1, 3, 4, 5]}, _}
          assert_received {:operation, %{operation: :send}, %{attachments: attachments}}
          assert Enum.map(attachments, & &1.attachment_index) == [0, 1, 3, 4, 5]
      end
    end
  end

  test "actual size drift and unknown metadata remain subject to fixed-group checks" do
    for declared <- [nil, 1, 8] do
      record = %{file("attachment", "12345678") | size: declared}
      connection = planning_connection(10, 1000, :abort)

      assert {:ok, planned} =
               Attachments.build_plan(
                 put_in(outgoing().delivery.attachments, [record]),
                 PlanningBridge,
                 connection
               )

      assert {:ok, _} = Executor.execute(planned, PlanningBridge, connection)
      assert_received {:operation, %{operation: :upload}, %{attachments: [%{size: 8}]}}
      assert_received {:operation, %{operation: :send}, _}
    end

    records = Enum.map(0..1, fn index -> %{file("attachment-#{index}", "12345678") | size: 1} end)

    connection =
      put_in(
        planning_connection(10, 1000, :abort).requirements.max_attachment_bytes_per_message,
        10
      )

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               connection
             )

    assert {:error, %{stage: :preparation}} =
             Executor.execute(planned, PlanningBridge, connection)

    assert [%{attachment_refs: [0, 1]}] = planned.delivery.plan.groups
    refute_received {:operation, _, _}
  end

  property "execution preserves indices and the streamed edit after leading materialization failures" do
    check all(omitted <- integer(1..5), max_runs: 20) do
      records =
        Enum.map(0..(omitted - 1), &file("unavailable-#{&1}", nil)) ++ [file("usable", "ok")]

      outgoing = %{
        outgoing()
        | metadata: %{message_id: "streamed"},
          delivery: %Outgoing.Delivery{attachments: records}
      }

      connection = planning_connection(1, 1000)
      assert {:ok, planned} = Attachments.build_plan(outgoing, PlanningBridge, connection)
      immutable = planned
      assert planned.delivery.plan.preparation_failures == []
      assert {:ok, report} = Executor.execute(planned, PlanningBridge, connection)

      assert Enum.map(report.failed_attachments, & &1.attachment_index) ==
               Enum.to_list(0..(omitted - 1))

      assert [%{delivered_attachment_indices: [^omitted]}] = report.messages
      assert planned == immutable
      assert_received {:operation, %{operation: :upload, attachment_refs: [^omitted]}, _}

      assert_received {:operation, %{operation: :edit, attachment_refs: [^omitted]},
                       %{message_id: "streamed"}}

      refute_received {:operation, _, _}
    end
  end

  test "an oversized encoded text fallback is rejected after all attachment acquisitions fail" do
    connection = planning_connection(10, 1000)

    connection = %{
      connection
      | requirements: %{
          connection.requirements
          | transfer_mode: :send_with_attachments,
            max_encoded_message_bytes: 10
        }
    }

    outgoing = %{
      outgoing()
      | body: String.duplicate("x", 11),
        delivery: %Outgoing.Delivery{attachments: [file("missing", nil)]}
    }

    assert {:ok, planned} = Attachments.build_plan(outgoing, PlanningBridge, connection)

    assert {:error, %{delivery: :not_sent}} =
             Executor.execute(planned, PlanningBridge, connection)

    refute_received {:operation, _, _}
  end

  property "metadata grouping preserves order and assigns every eligible original index once" do
    check all(count <- integer(1..30), maximum <- integer(1..10)) do
      records = Enum.map(1..count, &file(to_string(&1), "bytes"))

      assert {:ok, planned} =
               Attachments.build_plan(
                 put_in(outgoing().delivery.attachments, records),
                 PlanningBridge,
                 planning_connection(maximum, 1000)
               )

      assert Enum.flat_map(planned.delivery.plan.groups, & &1.attachment_refs) ==
               Enum.to_list(0..(count - 1))

      assert Enum.all?(planned.delivery.plan.groups, &(length(&1.attachment_refs) <= maximum))
    end
  end

  test "requirements failures retain bridge-resolved policy before acquisition" do
    for policy <- [:continue, :abort] do
      connection =
        put_in(
          planning_connection(10, 1000, policy).requirements.max_attachment_bytes,
          :unresolved
        )

      outgoing = put_in(outgoing().delivery.attachments, [%Record{id: "lazy", kind: :file}])

      case policy do
        :abort ->
          assert {:error, %{stage: :configuration}} =
                   Attachments.build_plan(outgoing, PlanningBridge, connection)

        :continue ->
          assert {:ok, planned} =
                   Attachments.build_plan(outgoing, PlanningBridge, connection)

          assert Plan.failure_policy(planned.delivery.plan) == :continue
          assert planned.delivery.plan.requirements == nil

          assert [%{attachment_index: 0, stage: :configuration}] =
                   planned.delivery.plan.preparation_failures
      end
    end
  end

  defp outgoing, do: %Outgoing{provider: :mattermost, channel_id: "room", body: "Answer"}

  defp file(id, content, attributes \\ %{}),
    do: %Record{
      id: id,
      kind: :file,
      content: content,
      size: if(is_binary(content), do: byte_size(content)),
      name: "#{id}.txt",
      mime_type: "text/plain",
      attributes: attributes
    }

  defp planning_connection(count, request_bytes, policy \\ :continue) do
    %{
      test_pid: self(),
      settings: %{"send_on_file_failure" => policy == :continue},
      requirements: %TransportRequirements{
        failure_policy: policy,
        transfer_mode: :upload_then_publish,
        max_attachments_per_message: count,
        max_attachment_bytes: 1000,
        max_attachment_bytes_per_message: :not_applicable,
        max_encoded_message_bytes: :not_applicable,
        max_upload_request_bytes: request_bytes,
        supports_threads: true,
        supports_attachment_edits: true
      }
    }
  end

  test "continue prepares usable files and records safe failures in input order" do
    files = [
      file("first", "one"),
      file("bad", "%%%", %{"encoding" => "base64"}),
      file("last", "two")
    ]

    connection = planning_connection(10, 1000)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, files),
               PlanningBridge,
               connection
             )

    assert {:ok, %{attachments: prepared, preparation_failures: [failure]}} =
             Attachments.prepare_execution(planned, PlanningBridge, connection)

    assert Map.new(prepared, fn {index, file} -> {index, file.content} end) == %{
             0 => "one",
             2 => "two"
           }

    assert failure.attachment_index == 1
    assert failure.stage == :preparation
    assert failure.delivery == :not_sent
    refute inspect(failure) =~ "%%%"
  end

  test "continue publishes text with the original failure index after all preparations fail" do
    connection = planning_connection(10, 1000)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, [file("bad", nil)]),
               PlanningBridge,
               connection
             )

    assert {:ok,
            %{
              confirmation: :partial,
              failed_attachments: [%{attachment_index: 0}],
              messages: [receipt]
            }} =
             Executor.execute(planned, PlanningBridge, connection)

    assert receipt.body == "Answer"
    assert receipt.delivered_attachment_indices == []
    assert_received {:operation, %{operation: :send}, %{attachments: []}}
    refute_received {:operation, _, _}
  end

  test "abort preserves the original preparation error and publishes nothing" do
    records = [file("ok", "ready"), file("bad", "%%%", %{"encoding" => "base64"})]
    connection = planning_connection(10, 1000, :abort)

    assert {:ok, planned} =
             Attachments.build_plan(
               put_in(outgoing().delivery.attachments, records),
               PlanningBridge,
               connection
             )

    assert {:error, %{reason: :invalid_attachment_base64, stage: :preparation}} =
             Executor.execute(planned, PlanningBridge, connection)

    refute_received {:operation, _, _}
  end

  property "continue preserves every usable byte, order and original index around failed files" do
    check all(bytes <- list_of(binary(max_length: 256), min_length: 1, max_length: 10)) do
      records =
        Enum.flat_map(Enum.with_index(bytes), fn {content, index} ->
          [file("#{index}", content), file("invalid-#{index}", nil)]
        end)

      connection = planning_connection(100, 10_000)

      assert {:ok, planned} =
               Attachments.build_plan(
                 put_in(outgoing().delivery.attachments, records),
                 PlanningBridge,
                 connection
               )

      assert {:ok, %{attachments: prepared, preparation_failures: failures}} =
               Attachments.prepare_execution(planned, PlanningBridge, connection)

      ordered = prepared |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      assert Enum.map(ordered, & &1.content) == bytes

      assert Enum.map(ordered, & &1.attachment_index) ==
               Enum.map(Enum.with_index(bytes), fn {_, index} -> index * 2 end)

      assert length(failures) == length(bytes)
    end
  end
end
