defmodule Zaq.Channels.Delivery.ExecutorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Attachments, Error, Executor, Plan}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Engine.Messages.Outgoing

  defmodule OperationBridge do
    def prepare_upload_request(_attachments, _connection), do: {:ok, %{encoded_bytes: 0}}

    def execute_delivery_step(step, inputs, connection) do
      send(connection.test_pid, {:step_started, step.id, self(), inputs})

      case Map.get(connection.outcomes, step.id) do
        {:wait, outcome} ->
          receive do
            :release -> outcome || success(step)
          end

        :exit ->
          exit(:provider_exit)

        nil ->
          success(step)

        outcome ->
          outcome
      end
    end

    defp success(%{operation: :upload} = step) do
      {:ok,
       %{
         uploaded_attachments:
           Enum.map(step.attachment_refs, &%{id: "upload-#{&1}", attachment_index: &1})
       }}
    end

    defp success(step),
      do:
        {:ok,
         %{message_id: "message-#{step.group_id}", action: :created, confirmation: :confirmed}}
  end

  defmodule PreparedBridge do
    def prepare_upload_request(attachments, _connection),
      do: {:ok, %{encoded_bytes: 0, request: %{files: attachments}}}

    def prepare_delivery_message(outgoing, attachments, _connection),
      do: {:ok, %{encoded_bytes: 0, body: outgoing.body, files: attachments}}

    def execute_delivery_step(step, inputs, connection) do
      send(connection.test_pid, {:prepared_operation, step, inputs.prepared})
      OperationBridge.execute_delivery_step(step, inputs, connection)
    end
  end

  defmodule FallbackBridge do
    def transport_requirements(_outgoing, _connection) do
      {:error, error} = TransportRequirements.validate(nil)
      {:error, error, :continue}
    end

    defdelegate execute_delivery_step(step, inputs, connection), to: OperationBridge
  end

  test "prepared transport payloads stay in runtime inputs while the plan stays immutable" do
    outgoing = outgoing(:abort, 1, true)
    original_plan = outgoing.delivery.plan

    assert {:ok, %{confirmation: :confirmed}} =
             Executor.execute(outgoing, PreparedBridge, connection())

    assert_receive {:prepared_operation, upload, %{request: %{files: [file]}}}
    assert upload.operation == :upload
    assert file.content == "private bytes"
    refute Map.has_key?(upload, :prepared)

    assert_receive {:prepared_operation, publication, %{body: "Original answer", files: [^file]}}
    assert publication.operation == :send
    refute Map.has_key?(publication, :prepared)
    assert outgoing.delivery.plan == original_plan
    refute inspect(original_plan) =~ "private bytes"
  end

  test "requirements-error fallback publishes the answer without acquiring discarded files" do
    outgoing = outgoing(:continue, 1)

    outgoing =
      put_in(outgoing.delivery.attachments, [%Zaq.Contracts.Record{id: "lazy", kind: :file}])

    assert {:ok, planned} = Attachments.build_plan(outgoing, FallbackBridge, connection())
    assert planned.delivery.plan.requirements == nil
    assert Plan.failure_policy(planned.delivery.plan) == :continue

    assert {:ok, report} = Executor.execute(planned, FallbackBridge, connection())
    assert [%{body: "Original answer", delivered_attachment_indices: []}] = report.messages
    assert [%{attachment_index: 0, stage: :configuration}] = report.failed_attachments
    assert_receive {:step_started, {:send, 0}, _, %{attachments: [], prepared: nil}}
    refute_received {:step_started, {:upload, _}, _, _}
  end

  test "malformed-input notices publish notice text and retain the original canonical answer" do
    outgoing = outgoing(:continue, 1)

    error = %Error{
      reason: :invalid_attachments,
      message: "Files could not be sent.",
      stage: :planning,
      delivery: :not_sent
    }

    assert {:ok, planned} =
             Attachments.build_failure_plan(outgoing, error, FallbackBridge, connection())

    assert {:ok, report} = Executor.execute(planned, FallbackBridge, connection())
    assert [%{body: "Original answer", delivered_attachment_indices: []}] = report.messages

    assert_receive {:step_started, {:send, 0}, _,
                    %{
                      outgoing: %{body: "Original answer\n\nFiles could not be sent."},
                      attachments: []
                    }}
  end

  property "attachment-bearing plans require resolved constraints before preparation or transport" do
    check all(
            policy <- member_of([:abort, :continue]),
            invalid <- member_of([:missing, :unresolved, :invalid_policy, :plain_map])
          ) do
      outgoing = outgoing(policy, 1, true)
      requirements = outgoing.delivery.plan.requirements

      invalid_requirements =
        case invalid do
          :missing -> nil
          :unresolved -> %{requirements | max_attachment_bytes: :unresolved}
          :invalid_policy -> %{requirements | failure_policy: nil}
          :plain_map -> Map.from_struct(requirements)
        end

      outgoing = put_in(outgoing.delivery.plan.requirements, invalid_requirements)

      assert {:error, %{reason: :invalid_delivery_plan, delivery: :not_sent}} =
               Executor.execute(outgoing, PreparedBridge, connection())

      assert {:error, %{reason: :invalid_transport_requirements, delivery: :not_sent}} =
               Attachments.prepare_execution(outgoing, PreparedBridge, connection())

      refute_received {:prepared_operation, _, _}
      refute_received {:step_started, _, _, _}
    end
  end

  test "requirements-less fallback rejects attachment references in either owner and upload steps" do
    outgoing = outgoing(:continue, 1)
    assert {:ok, planned} = Attachments.build_plan(outgoing, FallbackBridge, connection())
    plan = planned.delivery.plan
    [group] = plan.groups
    [step] = plan.steps

    for invalid_plan <- [
          %{plan | groups: [%{group | attachment_refs: [0]}]},
          %{plan | steps: [%{step | attachment_refs: [0]}]},
          %{plan | steps: [%{step | operation: :upload}]},
          %{plan | preparation_failures: []}
        ] do
      outgoing = put_in(planned.delivery.plan, invalid_plan)

      assert {:error, %{reason: :invalid_delivery_plan}} =
               Executor.execute(outgoing, PreparedBridge, connection())

      assert {:error, %{reason: :invalid_transport_requirements}} =
               Attachments.prepare_execution(outgoing, PreparedBridge, connection())

      refute_received {:step_started, _, _, _}
    end
  end

  test "successful delivery retains the report for both multiple groups and a single group" do
    assert {:ok, multiple_group_report} =
             Executor.execute(outgoing(:continue, 2, true), OperationBridge, connection())

    assert %{
             confirmation: :confirmed,
             messages: [%{message_id: "message-0"}, %{message_id: "message-1"}],
             failed_attachments: [],
             unattempted_steps: []
           } = multiple_group_report

    assert {:ok, single_group_report} =
             Executor.execute(outgoing(:continue, 1, true), OperationBridge, connection())

    assert %{
             confirmation: :confirmed,
             messages: [%{message_id: "message-0", delivered_attachment_indices: [0]}],
             uploaded_attachments: [%{attachment_index: 0}],
             failed_attachments: [],
             unattempted_steps: [],
             step_outcomes: [_, _]
           } = single_group_report
  end

  test "fully confirmed delivery does not report that its messages were not sent" do
    assert {:ok, report} =
             Executor.execute(outgoing(:continue, 2, true), OperationBridge, connection())

    assert %{
             confirmation: :confirmed,
             messages: [
               %{message_id: "message-0", delivered_attachment_indices: [0]},
               %{message_id: "message-1", delivered_attachment_indices: [1]}
             ],
             failed_attachments: [],
             unattempted_steps: []
           } = report

    refute report[:delivery] == :not_sent,
           "Both messages and their attachments were confirmed, but the report says :not_sent"
  end

  test "stop uploads every group before publication and a later upload failure blocks all sends" do
    outgoing = outgoing(:abort, 3, true)
    connection = connection(%{{:upload, 1} => failure(:timeout)})

    assert {:error, %{reason: {:attachment_delivery_failed, report}}} =
             Executor.execute(outgoing, OperationBridge, connection)

    assert report.messages == []
    assert [%{attachment_index: 0}] = report.uploaded_only
    assert Enum.any?(report.unattempted_steps, &(&1.step_id == {:send, 0}))
    assert_receive {:step_started, {:upload, 0}, _, _}
    assert_receive {:step_started, {:upload, 1}, _, _}
    refute_received {:step_started, {:upload, 2}, _, _}
    refute_received {:step_started, {:send, _}, _, _}
  end

  test "stop retains the first confirmed message after the second publication fails" do
    assert {:ok, report} =
             Executor.execute(
               outgoing(:abort, 3),
               OperationBridge,
               connection(%{{:send, 1} => failure(:timeout)})
             )

    assert report.confirmation == :partial
    assert [%{message_id: "message-0"}] = report.messages
    assert [%{attachment_index: 1, delivery: :unconfirmed}] = report.failed_attachments
    assert [%{step_id: {:send, 2}}] = report.unattempted_steps
    refute_received {:step_started, {:send, 2}, _, _}
  end

  test "continue retains an unknown send and promotes the next candidate with the original answer" do
    assert {:ok, report} =
             Executor.execute(
               outgoing(:continue, 3),
               OperationBridge,
               connection(%{{:send, 0} => failure(:timeout)})
             )

    assert report.confirmation == :partial

    assert [
             %{message_id: "message-1", body: "Original answer"},
             %{message_id: "message-2", body: "Additional files (3/3)."}
           ] = report.messages

    assert [%{attachment_index: 0, reason: :timeout, delivery: :unconfirmed}] =
             report.failed_attachments

    assert_receive {:step_started, {:send, 1}, _,
                    %{outgoing: %{body: "Original answer"}, thread_id: nil}}

    assert_receive {:step_started, {:send, 2}, _, %{thread_id: "message-1"}}
    assert_receive {:step_started, {:send, 0}, _, _}
    refute_received {:step_started, {:send, 0}, _, _}
  end

  test "an unconfirmed edit does not turn the next group into another edit of the streamed message" do
    outgoing = outgoing(:continue, 2)
    [first, later] = outgoing.delivery.plan.steps
    first = %{first | operation: :edit, message_ref: {:existing, "streamed"}}
    outgoing = put_in(outgoing.delivery.plan.steps, [first, later])
    immutable = outgoing

    assert {:ok, _} =
             Executor.execute(
               outgoing,
               OperationBridge,
               connection(%{first.id => failure(:timeout)})
             )

    assert_receive {:step_started, id, _,
                    %{message_id: nil, outgoing: %{body: "Original answer"}}}

    assert id == later.id
    assert outgoing == immutable
  end

  test "duplicate step IDs are rejected before effects" do
    outgoing = outgoing(:continue, 1)
    [step] = outgoing.delivery.plan.steps

    outgoing = %{
      outgoing
      | delivery: %{outgoing.delivery | plan: %{outgoing.delivery.plan | steps: [step, step]}}
    }

    assert {:error, %{stage: :configuration}} =
             Executor.execute(outgoing, OperationBridge, connection())

    refute_received {:step_started, _, _, _}
  end

  test "continue overlaps ready replies within the configured bound" do
    connection = connection(Map.new(1..3, &{{:send, &1}, {:wait, nil}}))

    task =
      Task.async(fn ->
        Executor.execute(outgoing(:continue, 4), OperationBridge, connection, max_concurrency: 2)
      end)

    assert_receive {:step_started, {:send, 0}, _, _}
    assert_receive {:step_started, {:send, first}, first_pid, _} when first in [1, 2]
    assert_receive {:step_started, {:send, second}, second_pid, _} when second in [1, 2]
    refute first == second
    refute_received {:step_started, {:send, 3}, _, _}
    send(first_pid, :release)
    assert_receive {:step_started, {:send, 3}, third_pid, _}
    send(second_pid, :release)
    send(third_pid, :release)
    assert {:ok, %{confirmation: :confirmed, messages: messages}} = Task.await(task)
    assert Enum.map(messages, & &1.message_id) == Enum.map(0..3, &"message-#{&1}")
  end

  test "independent messages overlap under continue without waiting for a root" do
    outgoing = outgoing(:continue, 2)

    outgoing = %{
      outgoing
      | delivery: %{outgoing.delivery | plan: %{outgoing.delivery.plan | placement: :independent}}
    }

    connection = connection(Map.new(0..1, &{{:send, &1}, {:wait, nil}}))

    task =
      Task.async(fn ->
        Executor.execute(outgoing, OperationBridge, connection, max_concurrency: 2)
      end)

    assert_receive {:step_started, {:send, 0}, first, %{thread_id: nil}}
    assert_receive {:step_started, {:send, 1}, second, %{thread_id: nil}}
    send(first, :release)
    send(second, :release)
    assert {:ok, %{confirmation: :confirmed, messages: [root, continuation]}} = Task.await(task)
    assert root.body == "Original answer"
    assert continuation.body == "Additional files (2/2)."
  end

  test "task exits remain unconfirmed and are never retried" do
    assert {:ok, report} =
             Executor.execute(
               outgoing(:continue, 3),
               OperationBridge,
               connection(%{{:send, 1} => :exit})
             )

    assert report.confirmation == :partial

    assert Enum.any?(
             report.failed_attachments,
             &(&1.attachment_index == 1 and &1.delivery == :unconfirmed)
           )

    assert_receive {:step_started, {:send, 1}, _, _}
    refute_received {:step_started, {:send, 1}, _, _}
  end

  test "a timed out reply remains unknown without retrying the submitted step" do
    assert {:ok, report} =
             Executor.execute(
               outgoing(:continue, 3),
               OperationBridge,
               connection(%{{:send, 1} => {:wait, nil}}),
               timeout: 20
             )

    assert report.confirmation == :partial

    assert Enum.any?(
             report.failed_attachments,
             &(&1.attachment_index == 1 and &1.delivery == :unconfirmed)
           )

    assert_receive {:step_started, {:send, 1}, _, _}
    refute_received {:step_started, {:send, 1}, _, _}
    refute inspect(report) =~ "private bytes"
  end

  test "successful text followed by a failed attachment edit confirms only text" do
    outgoing = outgoing(:continue, 1, true)
    [upload, send] = outgoing.delivery.plan.steps
    text = %{send | attachment_refs: [], depends_on: []}

    edit = %Step{
      id: {:edit, 0},
      operation: :edit,
      group_id: 0,
      attachment_refs: [0],
      depends_on: [upload.id, text.id],
      message_ref: {:result, text.id}
    }

    outgoing = %{
      outgoing
      | delivery: %{
          outgoing.delivery
          | plan: %{outgoing.delivery.plan | steps: [upload, text, edit]}
        }
    }

    assert {:ok, report} =
             Executor.execute(
               outgoing,
               OperationBridge,
               connection(%{edit.id => failure(:timeout)})
             )

    assert [%{body: "Original answer", delivered_attachment_indices: []}] = report.messages
    assert [%{attachment_index: 0, delivery: :unconfirmed}] = report.failed_attachments
    assert [%{attachment_index: 0}] = report.uploaded_only

    assert_receive {:step_started, {:edit, 0}, _,
                    %{message_id: "message-0", outgoing: %{body: "Original answer"}}}
  end

  test "a blocked first root times out and the next root is promoted once" do
    assert {:ok, report} = timed_execution(outgoing(:continue, 3), {:send, 0})
    assert report.confirmation == :partial
    assert [%{attachment_index: 0, delivery: :unconfirmed}] = report.failed_attachments

    assert [
             %{message_id: "message-1", body: "Original answer"},
             %{message_id: "message-2", thread_id: "message-1"}
           ] = report.messages

    assert_receive {:step_started, {:send, 1}, _, %{thread_id: nil}}
    assert_receive {:step_started, {:send, 2}, _, %{thread_id: "message-1"}}
    refute_received {:step_started, _, _, _}
  end

  test "the single remaining reply times out after a confirmed root" do
    assert {:ok, report} = timed_execution(outgoing(:continue, 2), {:send, 1})
    assert [%{message_id: "message-0"}] = report.messages
    assert [%{attachment_index: 1, delivery: :unconfirmed}] = report.failed_attachments
    assert_receive {:step_started, {:send, 0}, _, _}
    refute_received {:step_started, _, _, _}
  end

  test "sole send and existing-message edit both honor the deadline" do
    for operation <- [:send, :edit], placement <- [:threaded, :independent] do
      outgoing = outgoing(:continue, 1)
      [step] = outgoing.delivery.plan.steps

      step = %{
        step
        | id: {operation, 0},
          operation: operation,
          message_ref: if(operation == :edit, do: {:existing, "streamed"})
      }

      plan = %{outgoing.delivery.plan | steps: [step], placement: placement}

      assert {:error, %{delivery: :unconfirmed, reason: {:attachment_delivery_failed, report}}} =
               timed_execution(
                 %{outgoing | delivery: %{outgoing.delivery | plan: plan}},
                 step.id
               )

      assert report.messages == []
      assert [%{attachment_index: 0, delivery: :unconfirmed}] = report.failed_attachments
      refute_received {:step_started, _, _, _}
    end
  end

  test "stop times out publication and preserves earlier confirmations without later sends" do
    assert {:ok, report} = timed_execution(outgoing(:abort, 3), {:send, 1})
    assert [%{message_id: "message-0"}] = report.messages
    assert [%{attachment_index: 1, delivery: :unconfirmed}] = report.failed_attachments
    assert [%{step_id: {:send, 2}}] = report.unattempted_steps
    assert_receive {:step_started, {:send, 0}, _, _}
    refute_received {:step_started, _, _, _}
  end

  test "stop upload timeout prevents all publication and later uploads" do
    assert {:error, %{reason: {:attachment_delivery_failed, report}}} =
             timed_execution(outgoing(:abort, 3, true), {:upload, 1})

    assert report.messages == []
    assert [%{attachment_index: 0}] = report.uploaded_only
    assert [%{attachment_index: 1, delivery: :unconfirmed}] = report.failed_attachments
    assert Enum.any?(report.unattempted_steps, &(&1.step_id == {:upload, 2}))
    assert_receive {:step_started, {:upload, 0}, _, _}
    refute_received {:step_started, _, _, _}
  end

  test "continue makes progress after an upload times out without retrying it" do
    assert {:ok, report} = timed_execution(outgoing(:continue, 2, true), {:upload, 0})
    assert report.confirmation == :partial
    assert [%{attachment_index: 0, delivery: :unconfirmed}] = report.failed_attachments

    assert [%{delivered_attachment_indices: []}, %{delivered_attachment_indices: [1]}] =
             report.messages

    assert_receive {:step_started, {:upload, 1}, _, _}
    assert_receive {:step_started, {:send, 0}, _, %{attachments: []}}

    assert_receive {:step_started, {:send, 1}, _,
                    %{uploaded_attachments: [%{attachment_index: 1}]}}

    refute_received {:step_started, _, _, _}
  end

  defp timed_execution(outgoing, blocked_id) do
    connection = connection(%{blocked_id => {:wait, nil}})

    task =
      Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn ->
        Executor.execute(outgoing, OperationBridge, connection, timeout: 50)
      end)

    try do
      assert_receive {:step_started, ^blocked_id, provider, _}, 1000
      monitor = Process.monitor(provider)

      try do
        assert {:ok, result} = Task.yield(task, 1000)
        assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 1000
        refute Process.alive?(provider)
        refute_received {:step_started, ^blocked_id, _, _}
        result
      after
        Process.demonitor(monitor, [:flush])
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "partial upload facts publish only confirmed references under continue" do
    outgoing = outgoing(:continue, 2, true)
    group = %{id: 0, attachment_refs: [0, 1]}
    upload = %Step{id: :upload, operation: :upload, group_id: 0, attachment_refs: [0, 1]}

    send = %Step{
      id: :send,
      operation: :send,
      group_id: 0,
      attachment_refs: [0, 1],
      depends_on: [:upload]
    }

    plan = %{outgoing.delivery.plan | groups: [group], steps: [upload, send]}
    {_, error, _} = failure(:timeout)

    result =
      {:error, error, %{uploaded_attachments: [%{id: "confirmed-upload", attachment_index: 0}]}}

    assert {:ok, report} =
             Executor.execute(
               %{outgoing | delivery: %{outgoing.delivery | plan: plan}},
               OperationBridge,
               connection(%{upload.id => result})
             )

    assert [%{delivered_attachment_indices: [0]}] = report.messages
    assert [%{attachment_index: 1}] = report.failed_attachments
    assert report.uploaded_only == []
  end

  test "an unknown text-only publication retains unknown certainty" do
    outgoing = outgoing(:continue, 1)
    [step] = outgoing.delivery.plan.steps
    plan = %{outgoing.delivery.plan | steps: [%{step | attachment_refs: []}]}

    assert {:error, %{delivery: :unconfirmed, reason: {:attachment_delivery_failed, report}}} =
             Executor.execute(
               %{outgoing | delivery: %{outgoing.delivery | plan: plan}},
               OperationBridge,
               connection(%{step.id => failure(:timeout)})
             )

    assert report.failed_attachments == []
    assert [%{delivery: :unconfirmed, status: :failed}] = report.step_outcomes
  end

  property "only reports without confirmed messages carry overall error certainty" do
    check all(
            count <- integer(1..6),
            confirmed_count <- integer(0..count),
            policy <- member_of([:continue, :abort]),
            certainty <- member_of([:not_sent, :unconfirmed])
          ) do
      error = %Error{
        reason: :provider_failure,
        message: "Provider did not confirm delivery.",
        stage: :transport,
        delivery: certainty
      }

      outcomes =
        for index <- 0..(count - 1),
            index >= confirmed_count,
            into: %{},
            do: {{:send, index}, {:error, error, %{}}}

      result = Executor.execute(outgoing(policy, count), OperationBridge, connection(outcomes))

      report =
        if confirmed_count == 0 do
          assert {:error,
                  %Error{
                    reason: {:attachment_delivery_failed, report},
                    cause: :provider_failure,
                    message: "Provider did not confirm delivery.",
                    stage: :transport,
                    delivery: ^certainty
                  }} = result

          assert report.confirmation == :unconfirmed
          assert report.delivery == certainty
          report
        else
          assert {:ok, report} = result

          assert report.confirmation ==
                   if(confirmed_count == count, do: :confirmed, else: :partial)

          refute Map.has_key?(report, :delivery)
          report
        end

      assert length(report.messages) == confirmed_count

      expected_failures =
        if policy == :abort and confirmed_count < count, do: 1, else: count - confirmed_count

      assert length(report.failed_attachments) == expected_failures
      assert Enum.all?(report.failed_attachments, &(&1.delivery == certainty))

      failed_steps = Enum.filter(report.step_outcomes, &(&1.status == :failed))
      assert length(failed_steps) == expected_failures
      assert Enum.all?(failed_steps, &(&1.delivery == certainty))
      collect_started([])
    end
  end

  property "successful execution retains complete reports across group counts and policies" do
    check all(count <- integer(1..6), policy <- member_of([:continue, :abort])) do
      assert {:ok, report} =
               Executor.execute(outgoing(policy, count, true), OperationBridge, connection())

      assert report.confirmation == :confirmed

      assert Enum.map(report.messages, & &1.message_id) ==
               Enum.map(0..(count - 1), &"message-#{&1}")

      assert Enum.map(report.messages, & &1.delivered_attachment_indices) ==
               Enum.map(0..(count - 1), &[&1])

      assert Enum.map(report.uploaded_attachments, & &1.attachment_index) ==
               Enum.to_list(0..(count - 1))

      assert report.failed_attachments == []
      assert report.uploaded_only == []
      assert report.unattempted_steps == []
      assert length(report.step_outcomes) == count * 2
      assert Enum.all?(report.step_outcomes, &(&1.status == :confirmed))
      collect_started([])
    end
  end

  property "every planned step starts at most once and receives resolved upload outputs" do
    check all(count <- integer(1..10), policy <- member_of([:continue, :abort])) do
      assert {:ok, _} =
               Executor.execute(
                 outgoing(policy, count, true),
                 OperationBridge,
                 connection()
               )

      started = collect_started([])
      ids = Enum.map(started, &elem(&1, 0))
      assert length(ids) == length(Enum.uniq(ids))
      assert length(ids) == count * 2

      for {{:send, index}, inputs} <- started do
        assert [%{attachment_index: ^index}] = inputs.uploaded_attachments
      end
    end
  end

  defp collect_started(started) do
    receive do
      {:step_started, id, _pid, inputs} -> collect_started([{id, inputs} | started])
    after
      0 -> Enum.reverse(started)
    end
  end

  defp failure(reason),
    do:
      {:error,
       %Error{
         reason: reason,
         message: "Delivery could not be confirmed.",
         stage: :transport,
         delivery: :unconfirmed
       }, %{}}

  defp connection(outcomes \\ %{}), do: %{test_pid: self(), outcomes: outcomes}

  defp outgoing(policy, count, uploads? \\ false) do
    groups =
      Enum.map(
        0..(count - 1),
        &%{id: &1, attachment_refs: [&1]}
      )

    steps =
      Enum.flat_map(groups, fn group ->
        upload = %Step{
          id: {:upload, group.id},
          operation: :upload,
          group_id: group.id,
          attachment_refs: group.attachment_refs
        }

        send = %Step{
          id: {:send, group.id},
          operation: :send,
          group_id: group.id,
          attachment_refs: group.attachment_refs,
          depends_on: if(uploads?, do: [upload.id], else: [])
        }

        if uploads?, do: [upload, send], else: [send]
      end)

    files =
      Map.new(
        groups,
        &{&1.id,
         %{
           attachment_index: &1.id,
           content: "private bytes",
           name: "file.txt",
           mime_type: "text/plain",
           size: 13
         }}
      )

    %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: "Original answer",
      delivery: %Outgoing.Delivery{
        attachments:
          Enum.map(Map.values(files), fn attachment ->
            %Zaq.Contracts.Record{
              id: to_string(attachment.attachment_index),
              kind: :file,
              content: attachment.content,
              name: attachment.name,
              mime_type: attachment.mime_type,
              size: attachment.size
            }
          end),
        plan: %Plan{
          requirements: %TransportRequirements{
            failure_policy: policy,
            transfer_mode: if(uploads?, do: :upload_then_publish, else: :send_with_attachments),
            max_attachments_per_message: 10,
            max_attachment_bytes: :not_applicable,
            max_attachment_bytes_per_message: :not_applicable,
            max_encoded_message_bytes: :not_applicable,
            max_upload_request_bytes: :not_applicable,
            supports_threads: true
          },
          placement: :threaded,
          groups: groups,
          steps: steps
        }
      }
    }
  end
end
