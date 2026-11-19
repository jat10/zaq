defmodule Zaq.Channels.DeliveryExecutor do
  @moduledoc """
  Executes one private Channel delivery plan through single-operation bridges.

  Stop uploads finish before any publication, then publication is sequential.
  Continue elects a confirmed root without retrying failed candidates and runs
  ready replies with bounded concurrency under the existing task supervisor.
  Every upload, send and edit runs in a supervised task with the configured step
  timeout. Timed-out operations remain unconfirmed and are never retried.
  Results retain stable plan order and original attachment indices. Uploaded
  references alone never confirm message delivery. No operation is retried.
  """

  alias Zaq.Channels.{DeliveryAttachments, DeliveryError, DeliveryPlan}
  alias Zaq.Engine.Messages.Outgoing

  require Logger

  @doc "Executes planned effects once and returns confirmed receipts plus failure evidence."
  @spec execute(Outgoing.t(), module(), map(), keyword()) ::
          {:ok, map()} | {:error, DeliveryError.t()}
  def execute(outgoing, bridge, connection, opts \\ [])

  def execute(
        %Outgoing{
          delivery: %Outgoing.Delivery{plan: %DeliveryPlan{} = plan}
        } = outgoing,
        bridge,
        connection,
        opts
      ) do
    with :ok <- validate_plan(plan, outgoing),
         {:ok, runtime} <- execution_context(outgoing, bridge, connection, opts),
         {:ok, preparation} <-
           DeliveryAttachments.prepare_execution(outgoing, bridge, runtime.connection) do
      runtime = Map.merge(runtime, preparation)

      state = %{
        results: %{},
        root_message_id: outgoing.thread_id,
        answer_confirmed?: false,
        halted?: false
      }

      state = run_uploads(runtime, state)
      state = if state.halted?, do: state, else: run_publications(runtime, state)
      finish(runtime, state)
    end
  end

  def execute(_outgoing, _bridge, _connection, _opts), do: {:error, configuration_error()}

  defp execution_context(outgoing, bridge, connection, opts) do
    concurrency =
      Keyword.get(
        opts,
        :max_concurrency,
        Zaq.Config.get(:zaq, :delivery_max_concurrency, 4, opts)
      )

    timeout =
      Keyword.get(opts, :timeout, Zaq.Config.get(:zaq, :delivery_step_timeout_ms, 30_000, opts))

    if is_integer(concurrency) and concurrency > 0 and
         (timeout == :infinity or (is_integer(timeout) and timeout > 0)) and
         Code.ensure_loaded?(bridge) and
         delivery_operations_available?(bridge, outgoing.delivery.plan) do
      {:ok,
       %{
         outgoing: outgoing,
         bridge: bridge,
         connection:
           connection
           |> Map.put(:delivery_channel_id, outgoing.channel_id)
           |> Map.put(:delivery_provider, outgoing.provider),
         plan: outgoing.delivery.plan,
         concurrency: concurrency,
         timeout: timeout
       }}
    else
      {:error, configuration_error()}
    end
  end

  defp delivery_operations_available?(bridge, plan) do
    function_exported?(bridge, :execute_delivery_step, 3) or
      (function_exported?(bridge, :send_reply, 2) and
         Enum.all?(plan.steps, &(&1.operation == :send)))
  end

  defp validate_plan(plan, outgoing) do
    ids = Enum.map(plan.steps, & &1.id)
    group_ids = Enum.map(plan.groups, & &1.id)

    valid? =
      plan.failure_policy in [:abort, :continue] and length(ids) == length(Enum.uniq(ids)) and
        Enum.all?(plan.steps, &valid_step?(&1, plan, outgoing, ids, group_ids))

    if valid? and acyclic?(plan.steps, MapSet.new()),
      do: :ok,
      else: {:error, configuration_error()}
  end

  defp valid_step?(step, plan, outgoing, ids, group_ids) do
    step.operation in [:upload, :send, :edit] and step.group_id in group_ids and
      Enum.all?(step.depends_on, &(&1 in ids and &1 != step.id)) and
      Enum.all?(
        step.attachment_refs,
        &(is_integer(&1) and &1 >= 0 and &1 < length(outgoing.delivery.attachments))
      ) and
      upload_dependencies?(step, plan.steps)
  end

  defp upload_dependencies?(%{operation: :upload} = step, steps),
    do:
      Enum.all?(step.depends_on, fn id ->
        Enum.any?(steps, &(&1.id == id and &1.operation == :upload))
      end)

  defp upload_dependencies?(_step, _steps), do: true

  defp acyclic?([], _resolved), do: true

  defp acyclic?(steps, resolved) do
    {ready, waiting} =
      Enum.split_with(steps, &Enum.all?(&1.depends_on, fn id -> MapSet.member?(resolved, id) end))

    ready != [] and acyclic?(waiting, Enum.reduce(ready, resolved, &MapSet.put(&2, &1.id)))
  end

  defp run_uploads(runtime, state) do
    runtime.plan.steps
    |> Enum.filter(&(&1.operation == :upload))
    |> Enum.reduce_while(state, fn step, state ->
      result =
        if dependency_status(step, state) == :ready,
          do: upload(step, runtime, state),
          else: %{status: :not_started}

      state = put_result(state, step, result)

      if runtime.plan.failure_policy == :abort and result.status != :confirmed,
        do: {:halt, %{state | halted?: true}},
        else: {:cont, state}
    end)
  end

  defp upload(step, runtime, state) do
    [result] = run_steps([step], runtime, &invoke(&1, inputs(&1, runtime, state), runtime))
    result
  end

  defp run_publications(runtime, state) do
    steps = Enum.reject(runtime.plan.steps, &(&1.operation == :upload))

    case runtime.plan.failure_policy do
      :abort -> run_sequential(steps, runtime, state)
      :continue -> run_continue(steps, runtime, state)
    end
  end

  defp run_sequential(steps, runtime, state) do
    Enum.reduce_while(steps, state, fn step, state ->
      [result] = run_ready([step], runtime, state)
      state = put_result(state, step, result)
      if result.status == :confirmed, do: {:cont, state}, else: {:halt, %{state | halted?: true}}
    end)
  end

  defp run_continue([], _runtime, state), do: state

  defp run_continue(steps, runtime, state) do
    {ready, waiting} = Enum.split_with(steps, &(dependency_status(&1, state) != :waiting))

    cond do
      ready == [] ->
        state

      not state.answer_confirmed? and runtime.plan.placement == :threaded ->
        [step | remaining] = ready
        [result] = run_ready([step], runtime, state)
        state = put_result(state, step, result)
        run_continue(remaining ++ waiting, runtime, state)

      true ->
        results = run_ready(ready, runtime, state)

        state =
          Enum.zip(ready, results)
          |> Enum.reduce(state, fn {step, result}, state ->
            put_result(state, step, result)
          end)

        run_continue(waiting, runtime, state)
    end
  end

  defp run_ready(steps, runtime, state),
    do: run_steps(steps, runtime, &publication(&1, runtime, state))

  defp run_steps(steps, runtime, operation) do
    Zaq.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(steps, operation,
      ordered: true,
      max_concurrency: max(runtime.concurrency, 1),
      timeout: runtime.timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, _reason} ->
        failed_result(execution_error(:task_exit), %{})
    end)
  end

  defp publication(step, runtime, state) do
    step = publication_step(step, runtime, state)
    inputs = inputs(step, runtime, state)

    cond do
      dependency_status(step, state) != :ready ->
        %{status: :not_started}

      step.message_ref != nil and inputs.message_id == nil ->
        %{status: :not_started}

      skip_attachment_publication?(step, inputs, runtime, state) ->
        %{status: :not_started}

      true ->
        invoke(step, inputs, runtime)
    end
  end

  defp skip_attachment_publication?(step, inputs, runtime, state) do
    step.attachment_refs != [] and inputs.attachments == [] and
      (state.answer_confirmed? or
         (preparation_omitted?(step, runtime) and later_usable_group?(step, runtime, state)))
  end

  defp publication_step(%{operation: :send} = step, runtime, %{answer_confirmed?: false} = state) do
    case Enum.find(runtime.plan.steps, &(&1.operation == :edit)) do
      %{message_ref: {:existing, _} = reference, group_id: group_id} = earlier
      when group_id < step.group_id ->
        if get_in(state.results, [earlier.id, :status]) == :not_started and
             preparation_omitted?(earlier, runtime),
           do: %{step | operation: :edit, message_ref: reference},
           else: step

      _ ->
        step
    end
  end

  defp publication_step(step, _runtime, _state), do: step

  defp preparation_omitted?(step, runtime) do
    Enum.all?(step.attachment_refs, &(not Map.has_key?(runtime.attachments, &1))) or
      Enum.any?(step.depends_on, &Map.has_key?(runtime.preparation_errors, &1))
  end

  defp later_usable_group?(step, runtime, state) do
    Enum.any?(runtime.plan.steps, fn candidate ->
      candidate.operation != :upload and candidate.group_id > step.group_id and
        not Map.has_key?(runtime.preparation_errors, candidate.id) and
        inputs(candidate, runtime, state).attachments != []
    end)
  end

  defp dependency_status(step, state) do
    Enum.reduce_while(step.depends_on, :ready, fn id, _status ->
      case Map.get(state.results, id) do
        nil ->
          {:halt, :waiting}

        %{status: :not_started} ->
          {:halt, :blocked}

        %{operation: operation, status: status}
        when operation != :upload and status != :confirmed ->
          {:halt, :blocked}

        _ ->
          {:cont, :ready}
      end
    end)
  end

  defp inputs(step, runtime, state) do
    group = Enum.find(runtime.plan.groups, &(&1.id == step.group_id)) || %{}

    uploaded =
      step.depends_on
      |> Enum.flat_map(fn id -> get_in(state.results, [id, :uploaded_attachments]) || [] end)

    upload_dependencies? =
      Enum.any?(step.depends_on, fn id -> match?(%{operation: :upload}, state.results[id]) end)

    refs =
      if upload_dependencies?,
        do: Enum.map(uploaded, & &1.attachment_index),
        else: step.attachment_refs

    attachments =
      refs
      |> Enum.filter(&Map.has_key?(runtime.attachments, &1))
      |> Enum.map(&Map.fetch!(runtime.attachments, &1))

    body = publication_body(group, runtime, state)
    thread_id = resolved_thread(step, runtime, state)

    outgoing = %{
      runtime.outgoing
      | body: body,
        thread_id: thread_id,
        delivery: %{runtime.outgoing.delivery | plan: nil, attachments: [], error: nil}
    }

    outgoing =
      if group[:notice?],
        do: %{
          outgoing
          | metadata:
              Map.drop(outgoing.metadata || %{}, [:on_reply, "on_reply", :html_body, "html_body"]),
            delivery: %{outgoing.delivery | attachments: [], error: nil}
        },
        else: outgoing

    %{
      outgoing: outgoing,
      attachments: attachments,
      uploaded_attachments: uploaded,
      continuation?: continuation?(group, runtime, state),
      thread_id: thread_id,
      message_id: resolve_message_ref(step.message_ref, state),
      group: group
    }
  end

  defp publication_body(group, runtime, state) do
    if continuation?(group, runtime, state) do
      ordinal = Enum.find_index(runtime.plan.groups, &(&1.id == group.id)) + 1
      "Additional files (#{ordinal}/#{length(runtime.plan.groups)})."
    else
      Map.get(group, :body, runtime.outgoing.body)
    end
  end

  defp continuation?(group, %{plan: %{placement: :independent, groups: [first | _]}}, _state),
    do: group.id != first.id

  defp continuation?(_group, _runtime, %{answer_confirmed?: false}), do: false

  defp continuation?(group, _runtime, state) do
    not Enum.any?(state.results, fn {_id, result} ->
      result[:group_id] == group.id and result[:receipt] != nil
    end)
  end

  defp resolved_thread(%{message_ref: {:result, id}}, _runtime, state),
    do: get_in(state.results, [id, :receipt, :thread_id])

  defp resolved_thread(_step, %{plan: %{placement: :threaded}}, state), do: state.root_message_id
  defp resolved_thread(_step, _runtime, _state), do: nil

  defp resolve_message_ref({:existing, id}, _state), do: id

  defp resolve_message_ref({:result, id}, state),
    do: get_in(state.results, [id, :receipt, :message_id])

  defp resolve_message_ref(_reference, _state), do: nil

  defp invoke(step, inputs, runtime) do
    step = %{
      step
      | prepared: Map.get(runtime.prepared_steps, step.id),
        attachment_refs: Enum.map(inputs.attachments, & &1.attachment_index)
    }

    case Map.fetch(runtime.preparation_errors, step.id) do
      {:ok, error} -> failed_result(error, %{})
      :error -> invoke_prepared(step, inputs, runtime)
    end
  end

  defp invoke_prepared(step, inputs, runtime) do
    case call_operation(step, inputs, runtime) do
      {:ok, output} when is_map(output) ->
        normalize_success(step, inputs, output)

      {:error, %DeliveryError{} = error, output} when is_map(output) ->
        failed_result(error, output)

      {:error, %DeliveryError{} = error} ->
        failed_result(error, %{})

      _ ->
        failed_result(execution_error(:invalid_operation_result), %{})
    end
  rescue
    _ -> failed_result(execution_error(:operation_exception), %{})
  catch
    _, _ -> failed_result(execution_error(:operation_exit), %{})
  end

  defp call_operation(%{operation: :upload}, %{attachments: []}, _runtime),
    do: {:ok, %{uploaded_attachments: []}}

  defp call_operation(step, inputs, runtime) do
    if function_exported?(runtime.bridge, :execute_delivery_step, 3) do
      runtime.bridge.execute_delivery_step(step, inputs, runtime.connection)
    else
      outgoing = %{
        inputs.outgoing
        | delivery: %{inputs.outgoing.delivery | attachments: [], error: nil}
      }

      response =
        if inputs.attachments == [],
          do: runtime.bridge.send_reply(outgoing, runtime.connection),
          else: {:error, configuration_error()}

      case response do
        :ok -> {:ok, %{confirmation: :unconfirmed}}
        {:error, %DeliveryError{}} = error -> error
        {:error, reason} -> {:error, execution_error(reason)}
        result -> result
      end
    end
  end

  defp normalize_success(%{operation: :upload} = step, _inputs, output) do
    uploaded = uploaded_attachments(output)

    if is_list(uploaded) and
         Enum.sort(Enum.map(uploaded, & &1.attachment_index)) == Enum.sort(step.attachment_refs),
       do: %{status: :confirmed, uploaded_attachments: uploaded},
       else: failed_result(execution_error(:invalid_upload_confirmation), output)
  end

  defp normalize_success(_step, inputs, output) do
    if output[:confirmation] == :confirmed and present_id?(output[:message_id]) do
      receipt =
        output
        |> Map.put(:body, Map.get(inputs.group, :canonical_body, inputs.outgoing.body))
        |> Map.put_new(:thread_id, inputs.thread_id)
        |> Map.put(
          :delivered_attachment_indices,
          Enum.map(inputs.attachments, & &1.attachment_index)
        )

      %{status: :confirmed, receipt: receipt}
    else
      failed_result(execution_error(:unconfirmed_publication), %{})
    end
  end

  defp present_id?(id), do: (is_binary(id) and id != "") or is_integer(id)

  defp failed_result(error, output),
    do: %{status: :failed, error: error, uploaded_attachments: uploaded_attachments(output)}

  defp uploaded_attachments(output) do
    case Map.get(output, :uploaded_attachments, []) do
      attachments when is_list(attachments) ->
        Enum.filter(attachments, fn attachment ->
          is_map(attachment) and is_integer(attachment[:attachment_index]) and
            present_id?(attachment[:id])
        end)

      _ ->
        []
    end
  end

  defp put_result(state, step, result) do
    if result[:error] do
      Logger.warning(
        "[DeliveryExecutor] step failed stage=#{result.error.stage} reason=#{inspect(safe_reason(result.error))}"
      )
    end

    result = result |> Map.put(:operation, step.operation) |> Map.put(:group_id, step.group_id)
    state = %{state | results: Map.put(state.results, step.id, result)}

    if step.operation != :upload and result.status == :confirmed do
      root = state.root_message_id || result.receipt[:thread_id] || result.receipt.message_id

      %{state | root_message_id: root, answer_confirmed?: true}
    else
      state
    end
  end

  defp finish(runtime, state) do
    report = report(runtime, state)

    case report.messages do
      [] ->
        cause = first_error(runtime.plan.steps, state)

        {:error,
         %DeliveryError{
           reason: {:attachment_delivery_failed, report},
           cause: cause.reason,
           message: cause.message,
           stage: :transport,
           delivery: report.delivery
         }}

      _ ->
        notify_completed(runtime, report)

        if length(runtime.plan.groups) == 1 and report.confirmation == :confirmed,
          do: {:ok, hd(report.messages)},
          else: {:ok, report}
    end
  end

  defp first_error(steps, state) do
    Enum.find_value(steps, execution_error(:unconfirmed_publication), fn step ->
      get_in(state.results, [step.id, :error])
    end)
  end

  defp report(runtime, state) do
    results =
      Enum.map(runtime.plan.steps, &{&1, Map.get(state.results, &1.id, %{status: :not_started})})

    messages =
      results
      |> Enum.flat_map(fn {_step, result} ->
        if result[:receipt], do: [result.receipt], else: []
      end)
      |> compose_receipts()
      |> continuation_indices()

    uploaded =
      Enum.flat_map(results, fn {_step, result} -> result[:uploaded_attachments] || [] end)

    failed =
      results
      |> Enum.reject(fn {step, _result} -> Map.has_key?(runtime.preparation_errors, step.id) end)
      |> Enum.flat_map(&step_failures(&1, runtime.attachments))

    unattempted =
      for {step, %{status: :not_started}} <- results,
          do: %{
            step_id: step.id,
            group_id: step.group_id,
            attachment_indices: step.attachment_refs
          }

    delivered = Enum.flat_map(messages, & &1.delivered_attachment_indices)
    failures = runtime.preparation_failures ++ failed

    uncertain? =
      Enum.any?(results, fn {_step, result} ->
        match?(%{error: %{delivery: :unconfirmed}}, result)
      end)

    last = List.last(messages) || %{}

    summary =
      Map.take(last, [
        :anchor,
        :thread_metadata,
        :thread_id,
        :conversation_id,
        :source_scope,
        :audience
      ])

    Map.merge(summary, %{
      confirmation: report_confirmation(messages, failures, unattempted),
      message_id: last[:message_id],
      action: last[:action],
      messages: messages,
      failed_attachments: failures,
      uploaded_attachments: Enum.map(uploaded, &public_upload/1),
      uploaded_only:
        uploaded |> Enum.reject(&(&1.attachment_index in delivered)) |> Enum.map(&public_upload/1),
      unattempted_steps: unattempted,
      step_outcomes: Enum.map(results, &public_outcome/1),
      stage: failure_stage(results),
      delivery: if(uncertain?, do: :unconfirmed, else: :not_sent)
    })
  end

  defp report_confirmation([], _failures, _unattempted), do: :unconfirmed
  defp report_confirmation(_messages, [], []), do: :confirmed
  defp report_confirmation(_messages, _failures, _unattempted), do: :partial

  defp step_failures({step, %{status: :failed, error: error} = result}, attachments) do
    uploaded =
      if step.operation == :upload,
        do: Enum.map(result.uploaded_attachments, & &1.attachment_index),
        else: []

    step.attachment_refs
    |> Enum.reject(&(&1 in uploaded))
    |> Enum.map(fn index ->
      %{
        attachment_index: index,
        stage: error.stage,
        delivery: error.delivery,
        reason: safe_reason(error),
        step_id: step.id,
        group_id: step.group_id,
        filename: get_in(attachments, [index, :name]),
        size: get_in(attachments, [index, :size])
      }
    end)
  end

  defp step_failures(_result, _files), do: []

  defp failure_stage(results) do
    Enum.find_value(results, fn {_step, result} -> if result[:error], do: result.error.stage end)
  end

  defp safe_reason(%{reason: reason}) when is_atom(reason) and not is_nil(reason), do: reason
  defp safe_reason(%{reason: {:http_error, status} = reason}) when status in 100..599, do: reason
  defp safe_reason(error), do: error.message

  defp public_upload(upload),
    do: Map.take(upload, [:id, :filename, :media_type, :size_bytes, :attachment_index])

  defp public_outcome({step, result}) do
    outcome = %{
      step_id: step.id,
      group_id: step.group_id,
      operation: step.operation,
      status: result.status
    }

    if result[:error],
      do:
        Map.merge(outcome, %{delivery: result.error.delivery, reason: safe_reason(result.error)}),
      else: outcome
  end

  defp compose_receipts(messages) do
    Enum.reduce(messages, [], fn receipt, composed ->
      case Enum.find_index(composed, &(&1.message_id == receipt.message_id)) do
        nil -> composed ++ [receipt]
        index -> List.update_at(composed, index, &Map.merge(&1, receipt))
      end
    end)
  end

  defp continuation_indices(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn
      {receipt, 0} -> receipt
      {receipt, index} -> Map.put(receipt, :delivery_part_index, index)
    end)
  end

  defp notify_completed(runtime, report) do
    notice? = Enum.any?(runtime.plan.groups, & &1[:notice?])

    if not notice? and function_exported?(runtime.bridge, :delivery_completed, 3),
      do:
        runtime.bridge.delivery_completed(
          %{runtime.outgoing | delivery: %{runtime.outgoing.delivery | plan: nil}},
          report,
          runtime.connection
        )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp execution_error(reason),
    do: %DeliveryError{
      reason: reason,
      message: "Delivery could not be confirmed.",
      stage: :execution,
      delivery: :unconfirmed
    }

  defp configuration_error,
    do: %DeliveryError{
      reason: :invalid_delivery_plan,
      message: "The delivery plan is invalid.",
      stage: :configuration,
      delivery: :not_sent
    }
end
