defmodule Zaq.Channels.Delivery.GroupExecutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Channels.Delivery.{Executor, Plan}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.TestSupport.GroupDeliveryBridge

  setup :verify_on_exit!

  test "fifteen files are acquired, prepared and uploaded in three groups before publication" do
    connection = connection()
    stub_acquisition(connection)
    outgoing = outgoing(:abort, 15, 5)

    assert {:ok, report} = Executor.execute(outgoing, GroupDeliveryBridge, connection)

    assert events() ==
             Enum.flat_map(
               [Enum.to_list(0..4), Enum.to_list(5..9), Enum.to_list(10..14)],
               fn refs ->
                 Enum.map(refs, &{:acquire, [&1]}) ++
                   [{:prepare_upload, refs}, {:prepare_message, refs}, {:upload, refs}]
               end
             ) ++
               [
                 {:send, Enum.to_list(0..4)},
                 {:send, Enum.to_list(5..9)},
                 {:send, Enum.to_list(10..14)}
               ]

    assert Enum.flat_map(report.messages, & &1.delivered_attachment_indices) ==
             Enum.to_list(0..14)

    assert report.failed_attachments == []
    assert report.uploaded_only == []

    assert_receive {:delivery_inputs, %{operation: :upload},
                    %{attachments: [%{content: "bytes"} | _]}}

    assert_receive {:delivery_inputs, %{operation: :send}, inputs}
    assert Enum.all?(inputs.attachments, &(not Map.has_key?(&1, :content)))
    assert_receive {:delivery_completed, completed, _}
    assert Enum.all?(completed.delivery.attachments, &is_nil(&1.content))
    assert Enum.all?(outgoing.delivery.attachments, &is_binary(&1.materialization_handle))
  end

  for policy <- [:abort, :continue],
      stage <- [:acquisition, :upload_preparation, :message_preparation, :upload],
      group <- [0, 1] do
    @tag failure_policy: policy, failure_stage: stage, failure_group: group
    test "#{policy} handles #{stage} failure in group #{group} before later acquisition", %{
      failure_policy: policy,
      failure_stage: stage,
      failure_group: group
    } do
      failure_index = group * 5
      connection = connection(%{failure_stage: stage, failure_index: failure_index})
      stub_acquisition(connection)

      result = Executor.execute(outgoing(policy, 15, 5), GroupDeliveryBridge, connection)
      events = events()
      acquired = for {:acquire, [index]} <- events, do: index
      publications = for {:send, refs} <- events, do: refs

      if policy == :abort do
        assert {:error, error} = result
        assert Enum.all?(acquired, &(&1 < (group + 1) * 5))
        assert publications == []

        if group == 1 or stage == :upload do
          assert {:attachment_delivery_failed, report} = error.reason

          assert Enum.map(report.uploaded_only, & &1.attachment_index) ==
                   if(group == 1, do: Enum.to_list(0..4), else: [])

          assert Enum.any?(report.failed_attachments, &(&1.attachment_index == failure_index))
          assert Enum.any?(report.unattempted_steps, &(&1.group_id == 2))
        else
          assert error.stage == :preparation
          assert error.delivery == :not_sent
        end
      else
        assert {:ok, report} = result
        assert acquired == Enum.to_list(0..14)
        assert Enum.any?(report.failed_attachments, &(&1.attachment_index == failure_index))
        assert Enum.any?(publications, &(10 in &1))
        assert report.confirmation == :partial

        assert Enum.map(report.uploaded_only, & &1.attachment_index) ==
                 if(stage == :message_preparation,
                   do: Enum.to_list(failure_index..(failure_index + 4)),
                   else: []
                 )
      end

      last_upload =
        events |> Enum.with_index() |> Enum.filter(fn {{kind, _}, _} -> kind == :upload end)

      first_send = Enum.find_index(events, fn {kind, _} -> kind == :send end)
      assert is_nil(first_send) or Enum.all?(last_upload, fn {_, index} -> index < first_send end)
      assert length(acquired) == length(Enum.uniq(acquired))
    end
  end

  test "multiple upload batches complete before the next group is acquired" do
    connection = connection()
    stub_acquisition(connection)
    outgoing = outgoing(:abort, 10, 5, 2)

    assert {:ok, _} = Executor.execute(outgoing, GroupDeliveryBridge, connection)
    events = events()

    assert Enum.filter(events, fn {kind, _} -> kind == :upload end) ==
             [
               {:upload, [0, 1]},
               {:upload, [2, 3]},
               {:upload, [4]},
               {:upload, [5, 6]},
               {:upload, [7, 8]},
               {:upload, [9]}
             ]

    assert Enum.find_index(events, &(&1 == {:upload, [4]})) <
             Enum.find_index(events, &(&1 == {:acquire, [5]}))
  end

  test "a later batch preparation failure retains earlier groups under abort" do
    connection = connection(%{failure_stage: :upload_preparation, failure_index: 7})
    stub_acquisition(connection)

    assert {:error, %{reason: {:attachment_delivery_failed, report}}} =
             Executor.execute(outgoing(:abort, 15, 5, 2), GroupDeliveryBridge, connection)

    assert Enum.map(report.uploaded_only, & &1.attachment_index) == Enum.to_list(0..4)
    assert Enum.map(report.failed_attachments, & &1.attachment_index) == [7, 8]
    refute {:acquire, [10]} in events()
    assert report.messages == []
  end

  for policy <- [:abort, :continue] do
    @tag failure_policy: policy
    test "#{policy} retains partial upload confirmations without retry", %{failure_policy: policy} do
      connection = connection(%{failure_stage: :upload, failure_index: 5, partial_count: 2})
      stub_acquisition(connection)
      result = Executor.execute(outgoing(policy, 15, 5), GroupDeliveryBridge, connection)

      report =
        case result do
          {:ok, report} -> report
          {:error, %{reason: {:attachment_delivery_failed, report}}} -> report
        end

      assert Enum.map(report.failed_attachments, & &1.attachment_index) == [7, 8, 9]
      assert Enum.count(events(), &(&1 == {:upload, Enum.to_list(5..9)})) == 1

      if policy == :abort do
        assert Enum.map(report.uploaded_only, & &1.attachment_index) == Enum.to_list(0..6)
        assert report.messages == []
      else
        assert Enum.flat_map(report.messages, & &1.delivered_attachment_indices) ==
                 Enum.to_list(0..6) ++ Enum.to_list(10..14)

        assert report.uploaded_only == []
      end
    end
  end

  test "shared original indices are acquired once and remain available to later groups" do
    connection = connection()
    stub_acquisition(connection)
    outgoing = outgoing(:abort, 2, 1)
    [first, second] = outgoing.delivery.plan.groups
    second = %{second | attachment_refs: [0, 1]}

    steps =
      Enum.map(outgoing.delivery.plan.steps, fn step ->
        if step.group_id == 1, do: %{step | attachment_refs: [0, 1]}, else: step
      end)

    outgoing = put_in(outgoing.delivery.plan.groups, [first, second])
    outgoing = put_in(outgoing.delivery.plan.steps, steps)

    assert {:ok, _} = Executor.execute(outgoing, GroupDeliveryBridge, connection)
    events = events()

    assert Enum.filter(events, fn {kind, _} -> kind == :acquire end) ==
             [{:acquire, [0]}, {:acquire, [1]}]

    assert {:upload, [0, 1]} in events
    assert_receive {:delivery_inputs, %{group_id: 1, operation: :upload}, inputs}
    assert Enum.map(inputs.attachments, & &1.content) == ["bytes", "bytes"]
  end

  test "direct-send preparation failure in a later group prevents every publication" do
    connection = connection(%{failure_stage: :message_preparation, failure_index: 5})
    stub_acquisition(connection)
    outgoing = outgoing(:abort, 10, 5)
    requirements = %{outgoing.delivery.plan.requirements | transfer_mode: :send_with_attachments}
    steps = Enum.reject(outgoing.delivery.plan.steps, &(&1.operation == :upload))
    steps = Enum.map(steps, &%{&1 | depends_on: []})
    outgoing = put_in(outgoing.delivery.plan.requirements, requirements)
    outgoing = put_in(outgoing.delivery.plan.steps, steps)

    assert {:error, %{stage: :preparation, delivery: :not_sent}} =
             Executor.execute(outgoing, GroupDeliveryBridge, connection)

    refute Enum.any?(events(), fn {kind, _} -> kind in [:upload, :send] end)
  end

  test "shared failed acquisitions are recorded once and never retried by later groups" do
    connection = connection(%{failure_stage: :acquisition, failure_index: 0})
    stub_acquisition(connection)
    outgoing = outgoing(:continue, 2, 1)
    [first, second] = outgoing.delivery.plan.groups
    second = %{second | attachment_refs: [0, 1]}

    steps =
      Enum.map(outgoing.delivery.plan.steps, fn step ->
        if step.group_id == 1, do: %{step | attachment_refs: [0, 1]}, else: step
      end)

    outgoing = put_in(outgoing.delivery.plan.groups, [first, second])
    outgoing = put_in(outgoing.delivery.plan.steps, steps)

    assert {:ok, report} = Executor.execute(outgoing, GroupDeliveryBridge, connection)
    assert [%{attachment_index: 0}] = report.failed_attachments
    assert [%{delivered_attachment_indices: [1]}] = report.messages
    assert Enum.count(events(), &(&1 == {:acquire, [0]})) == 1
  end

  for policy <- [:abort, :continue] do
    @tag failure_policy: policy
    test "#{policy} enforces actual file size in a later group before uploading it", %{
      failure_policy: policy
    } do
      connection = connection(%{actual_bytes: %{5 => "oversized"}})
      stub_acquisition(connection)
      outgoing = outgoing(policy, 15, 5)
      outgoing = put_in(outgoing.delivery.plan.requirements.max_attachment_bytes, 6)

      result = Executor.execute(outgoing, GroupDeliveryBridge, connection)

      case policy do
        :abort ->
          assert {:error, %{reason: {:attachment_delivery_failed, report}}} = result
          assert Enum.map(report.uploaded_only, & &1.attachment_index) == Enum.to_list(0..4)
          assert report.messages == []
          refute {:acquire, [10]} in events()

        :continue ->
          assert {:ok, report} = result
          assert [%{attachment_index: 5, stage: :preparation}] = report.failed_attachments

          assert Enum.flat_map(report.messages, & &1.delivered_attachment_indices) ==
                   Enum.to_list(0..4) ++ Enum.to_list(6..14)

          assert report.uploaded_only == []
      end
    end
  end

  test "a failed middle upload batch continues with its partial references and later batches" do
    connection = connection(%{failure_stage: :upload, failure_index: 2, partial_count: 1})
    stub_acquisition(connection)

    assert {:ok, report} =
             Executor.execute(outgoing(:continue, 10, 5, 2), GroupDeliveryBridge, connection)

    assert [%{attachment_index: 3}] = report.failed_attachments

    assert Enum.flat_map(report.messages, & &1.delivered_attachment_indices) ==
             [0, 1, 2] ++ Enum.to_list(4..9)

    assert report.uploaded_only == []
    assert Enum.count(events(), &(&1 == {:upload, [2, 3]})) == 1
  end

  property "abort stops later acquisition and preserves stable uploaded-only indices" do
    check all(count <- integer(2..15), failed <- integer(0..(count - 1))) do
      connection = connection(%{failure_stage: :upload, failure_index: failed})
      stub_acquisition(connection)

      assert {:error, %{reason: {:attachment_delivery_failed, report}}} =
               Executor.execute(outgoing(:abort, count, 1), GroupDeliveryBridge, connection)

      assert for({:acquire, [index]} <- events(), do: index) == Enum.to_list(0..failed)

      assert Enum.map(report.uploaded_only, & &1.attachment_index) ==
               Enum.take(0..(count - 1), failed)

      assert [%{attachment_index: ^failed}] = report.failed_attachments
      assert report.messages == []
    end
  end

  defp stub_acquisition(connection) do
    test_pid = self()

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{person_id: 123}
      index = String.to_integer(event.request.file_id)
      send(test_pid, {:delivery_event, :acquire, [index]})

      response =
        if connection[:failure_stage] == :acquisition and connection[:failure_index] == index do
          {:error, :source_unavailable}
        else
          bytes = Map.get(connection[:actual_bytes] || %{}, index, "bytes")

          {:ok,
           %{
             record: %Record{
               id: to_string(index),
               kind: :file,
               content: bytes,
               name: "#{index}.txt"
             }
           }}
        end

      %{event | response: response}
    end)
  end

  defp connection(extra \\ %{}),
    do:
      Map.merge(
        %{
          test_pid: self(),
          trusted_context: %{actor: %{person_id: 123}},
          node_router: Zaq.NodeRouterMock
        },
        extra
      )

  defp outgoing(policy, count, group_size, batch_size \\ 100) do
    records =
      Enum.map(0..(count - 1), fn index ->
        {:ok, handle} = DiskDocument.issue(to_string(index))

        %Record{
          id: to_string(index),
          kind: :file,
          name: "#{index}.txt",
          size: 5,
          materialization_handle: handle
        }
      end)

    groups =
      0..(count - 1)
      |> Enum.chunk_every(group_size)
      |> Enum.with_index(fn refs, id -> %{id: id, attachment_refs: refs} end)

    steps =
      Enum.flat_map(groups, fn group ->
        uploads =
          group.attachment_refs
          |> Enum.chunk_every(batch_size)
          |> Enum.with_index(fn refs, batch ->
            %Step{
              id: {:upload, group.id, batch},
              operation: :upload,
              group_id: group.id,
              attachment_refs: refs
            }
          end)

        uploads ++
          [
            %Step{
              id: {:send, group.id},
              operation: :send,
              group_id: group.id,
              attachment_refs: group.attachment_refs,
              depends_on: Enum.map(uploads, & &1.id)
            }
          ]
      end)

    %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: "Answer",
      delivery: %Outgoing.Delivery{
        attachments: records,
        plan: %Plan{
          groups: groups,
          steps: steps,
          placement: :threaded,
          requirements: %TransportRequirements{
            failure_policy: policy,
            transfer_mode: :upload_then_publish,
            max_attachments_per_message: group_size,
            max_attachment_bytes: :not_applicable,
            max_attachment_bytes_per_message: :not_applicable,
            max_encoded_message_bytes: :not_applicable,
            max_upload_request_bytes: :not_applicable,
            supports_threads: true
          }
        }
      }
    }
  end

  defp events(acc \\ []) do
    receive do
      {:delivery_event, kind, indices} -> events([{kind, indices} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
