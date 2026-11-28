defmodule Zaq.Channels.Delivery.Executor do
  @moduledoc """
  Executes a Channel-local metadata plan through single-operation bridge callbacks.

  Outgoing, Plan, the selected connection and trusted runtime context stay separate.
  Abort completes uploads and preflights every publication before sending.
  Each publication is revalidated with its final root/thread headers.
  Continue promotes threaded roots without retrying failed operations, then runs
  ready replies with bounded concurrency. Independent messages need no root.

  Every upload/send/edit uses the existing task supervisor and a per-operation
  deadline. Timeout or task exit remains unconfirmed; termination cannot prove
  provider rejection. Results retain plan order, actual provider IDs and failures.
  This runtime neither reports to Engine nor retries an operation.

  `:channel_delivery` configuration defaults to `step_timeout_ms: 30_000` and
  `max_concurrency: 4`. Per-call opts override these values and may supply `:context`,
  `:task_supervisor` and `:attempt_id`. Requirements-error fallback requires an
  explicit valid `:max_text_request_bytes` transport fact and never acquires files.
  """

  alias Zaq.Channels.Delivery.{Error, Plan, Preparation, Result}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Config
  alias Zaq.ConnectorConfig.FileSettings
  alias Zaq.Engine.Messages.{ConversationIdentity, Outgoing}

  @type response :: {:ok, Result.t()} | {:error, Error.t(), Result.t()} | {:error, Error.t()}

  @doc "Executes provider operations at most once, retaining confirmed and unsuccessful facts."
  @spec execute(Outgoing.t(), Plan.t() | {:error, term()}, module(), map(), keyword()) ::
          response()
  def execute(outgoing, plan, bridge, connection, opts \\ [])

  def execute(
        %Outgoing{attachments: records} = outgoing,
        %Plan{} = plan,
        bridge,
        connection,
        opts
      )
      when is_list(records) do
    with :ok <- Plan.validate(plan, length(records)),
         :ok <- compatible_phases(plan),
         {:ok, runtime} <- runtime(outgoing, plan, bridge, connection, opts),
         {:ok, preparation} <- Preparation.start(outgoing, plan, Keyword.get(opts, :context, %{})) do
      runtime
      |> Map.merge(%{
        preparation: preparation,
        results: %{},
        usable: %{},
        uploaded: %{},
        uploaded_file_metadata: %{},
        acquired: MapSet.new(),
        halted?: false,
        first_error: nil,
        answer_confirmed?: false,
        answer_reserved?: false,
        root: outgoing.thread_id,
        fallback_reserved?: false
      })
      |> prepare_attachments()
      |> publish()
      |> finish()
    else
      {:error, %Error{} = failure} -> {:error, failure}
      failure -> {:error, error(:configuration, :failed, :invalid_plan, failure)}
    end
  end

  def execute(
        %Outgoing{attachments: records} = outgoing,
        {:error, reason},
        bridge,
        connection,
        opts
      )
      when is_list(records) do
    if requirements_failure?(reason),
      do: execute_text_fallback(outgoing, reason, bridge, connection, opts),
      else: {:error, error(:configuration, :failed, :invalid_plan, reason)}
  end

  def execute(_outgoing, _plan, _bridge, _connection, _opts),
    do: {:error, error(:configuration, :failed, :invalid_plan)}

  defp runtime(outgoing, plan, bridge, connection, opts) do
    config = Config.get(:zaq, :channel_delivery, [], opts)
    build_runtime(outgoing, plan, bridge, connection, opts, config)
  end

  defp build_runtime(outgoing, plan, bridge, connection, opts, config) when is_list(config) do
    timeout = Keyword.get(opts, :step_timeout_ms, Keyword.get(config, :step_timeout_ms, 30_000))
    concurrency = Keyword.get(opts, :max_concurrency, Keyword.get(config, :max_concurrency, 4))
    supervisor = Keyword.get(opts, :task_supervisor, Zaq.TaskSupervisor)
    attempt_id = Keyword.get_lazy(opts, :attempt_id, &Ecto.UUID.generate/0)

    with true <- is_integer(timeout) and timeout > 0,
         true <- is_integer(concurrency) and concurrency > 0,
         {:ok, attempt_id} <- Ecto.UUID.cast(attempt_id),
         true <- valid_supervisor?(supervisor),
         true <- bridge_ready?(bridge, plan) do
      {:ok,
       %{
         outgoing: outgoing,
         plan: plan,
         bridge: bridge,
         connection: connection,
         timeout: timeout,
         concurrency: concurrency,
         supervisor: supervisor,
         attempt_id: attempt_id,
         started_at:
           Keyword.get_lazy(opts, :attempt_started_at, fn ->
             DateTime.to_iso8601(DateTime.utc_now())
           end),
         text_edits?: Keyword.get(opts, :text_edits?) == true
       }}
    else
      _ -> {:error, error(:configuration, :failed, :missing_configuration)}
    end
  end

  defp build_runtime(_outgoing, _plan, _bridge, _connection, _opts, _config),
    do: {:error, error(:configuration, :failed, :missing_configuration)}

  defp bridge_ready?(bridge, plan) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, :execute_delivery_step, 3) and
      function_exported?(bridge, :prepare_delivery_message, 3) and
      (is_nil(plan) or plan.requirements.transfer_mode != :upload_then_publish or
         function_exported?(bridge, :prepare_upload_request, 2))
  end

  defp valid_supervisor?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp valid_supervisor?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp valid_supervisor?(_), do: false

  defp compatible_phases(plan) do
    operations = Map.new(plan.steps, &{&1.id, &1.operation})

    valid? =
      Enum.all?(plan.steps, fn step ->
        step.operation != :upload or
          Enum.all?(step.depends_on, &(Map.get(operations, &1) == :upload))
      end)

    if valid? and plan.groups != [],
      do: :ok,
      else: {:error, error(:configuration, :failed, :invalid_plan)}
  end

  defp prepare_attachments(
         %{plan: %{requirements: %{transfer_mode: :upload_then_publish}}} = state
       ) do
    state = upload_pending(state, Enum.filter(state.plan.steps, &(&1.operation == :upload)))

    Enum.reduce_while(state.plan.groups, state, fn group, state ->
      state =
        if abort?(state) and not state.halted?,
          do: prepare_abort_group(state, group.id),
          else: state

      if state.halted?, do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp prepare_attachments(state) do
    Enum.reduce_while(state.plan.groups, state, fn group, state ->
      state = acquire_group(state, group.id)

      state =
        if abort?(state) and not state.halted?,
          do: prepare_abort_group(state, group.id),
          else: state

      if state.halted?, do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp acquire_group(state, id) do
    if MapSet.member?(state.acquired, id) do
      state
    else
      case Preparation.acquire_group(state.preparation, id) do
        {:ok, files, preparation} ->
          %{
            state
            | preparation: preparation,
              usable: Map.put(state.usable, id, Enum.map(files, & &1.index)),
              acquired: MapSet.put(state.acquired, id)
          }

        {:error, failure, preparation} ->
          %{
            state
            | preparation: preparation,
              halted?: true,
              first_error: state.first_error || failure
          }
      end
    end
  end

  defp prepare_abort_group(state, group_id) do
    step = Enum.find(state.plan.steps, &(&1.group_id == group_id and &1.operation != :upload))
    inputs = publication_inputs(state, step, true)

    case Preparation.prepare_step(
           state.preparation,
           step.id,
           inputs,
           state.bridge,
           state.connection
         ) do
      {:ok, _prepared, preparation} ->
        %{state | preparation: preparation}

      {:error, failure, preparation} ->
        %{
          state
          | preparation: preparation,
            halted?: true,
            first_error: state.first_error || failure
        }
    end
  end

  defp upload_pending(%{halted?: true} = state, _steps), do: state
  defp upload_pending(state, []), do: state

  defp upload_pending(state, steps) do
    step = Enum.find(steps, &(dependency_status(&1, state) == :ready))

    if step do
      state = acquire_group(state, step.group_id)
      state = if state.halted?, do: state, else: upload_step(state, step)
      upload_pending(state, Enum.reject(steps, &(&1.id == step.id)))
    else
      Enum.reduce(steps, state, &put_unattempted(&2, &1, :dependency_failed))
    end
  end

  defp upload_step(state, step) do
    files = raw_files(state, step.group_id) |> Enum.filter(&(&1.index in step.attachment_refs))

    if files == [] do
      put_unattempted(state, step, :dependency_failed)
    else
      inputs = %{outgoing: state.outgoing, attachments: files}

      case Preparation.prepare_step(
             state.preparation,
             step.id,
             inputs,
             state.bridge,
             state.connection
           ) do
        {:ok, prepared, preparation} ->
          state = %{state | preparation: preparation}
          job = %{step: step, inputs: Map.put(inputs, :prepared, prepared)}
          apply_results(state, [job], run_jobs([job], state))

        {:error, failure, preparation} ->
          state = %{
            state
            | preparation: preparation,
              first_error: state.first_error || failure,
              halted?: abort?(state)
          }

          put_unattempted(state, step, :dependency_failed)
      end
    end
  end

  defp publish(%{halted?: true} = state), do: state

  defp publish(state) do
    first =
      Enum.find(state.plan.groups, &(publication_files(state, &1.id) != [])) ||
        hd(state.plan.groups)

    state = Map.put(state, :original_group_id, first.id)
    publish_pending(state, Enum.reject(state.plan.steps, &(&1.operation == :upload)))
  end

  defp publish_pending(%{halted?: true} = state, _steps), do: state
  defp publish_pending(state, []), do: state

  defp publish_pending(state, steps) do
    {blocked, pending} = Enum.split_with(steps, &(dependency_status(&1, state) == :blocked))
    state = Enum.reduce(blocked, state, &put_unattempted(&2, &1, :dependency_failed))
    ready = Enum.filter(pending, &(dependency_status(&1, state) == :ready))

    ready =
      if abort?(state) or (state.plan.placement == :threaded and not state.answer_confirmed?),
        do: Enum.take(ready, 1),
        else: ready

    if ready == [] do
      Enum.reduce(pending, state, &put_unattempted(&2, &1, :dependency_failed))
    else
      {jobs, state} = Enum.reduce(ready, {[], state}, &prepare_publication(&2, &1))
      jobs = Enum.reverse(jobs)
      state = if state.halted?, do: state, else: apply_results(state, jobs, run_jobs(jobs, state))
      ids = MapSet.new(ready, & &1.id)
      publish_pending(state, Enum.reject(pending, &MapSet.member?(ids, &1.id)))
    end
  end

  defp prepare_publication({jobs, state}, step) do
    inputs = publication_inputs(state, step, false)

    if skip_empty?(state, step, inputs.attachments),
      do: {jobs, put_unattempted(state, step, :dependency_failed)},
      else: encode_publication(jobs, state, step, inputs)
  end

  defp encode_publication(jobs, state, step, inputs) do
    case Preparation.prepare_step(
           state.preparation,
           step.id,
           inputs,
           state.bridge,
           state.connection
         ) do
      {:ok, prepared, preparation} ->
        job = %{step: step, inputs: Map.put(inputs, :prepared, prepared)}

        state = %{
          state
          | preparation: preparation,
            answer_reserved?: state.answer_reserved? or not inputs.continuation?,
            fallback_reserved?: state.fallback_reserved? or inputs.attachments == []
        }

        {[job | jobs], state}

      {:error, failure, preparation} ->
        state = %{state | preparation: preparation, first_error: state.first_error || failure}
        unprepared_publication(jobs, state, step, inputs)
    end
  end

  defp unprepared_publication(jobs, state, step, inputs) do
    cond do
      abort?(state) ->
        {jobs, %{state | halted?: true}}

      inputs.attachments != [] and answer_pending?(state) and not later_usable?(state, step) ->
        fallback = %{
          inputs
          | attachments: [],
            outgoing: %{inputs.outgoing | body: state.outgoing.body}
        }

        encode_publication(jobs, state, step, fallback)

      true ->
        {jobs, put_unattempted(state, step, :dependency_failed)}
    end
  end

  defp continuation?(state, step, files, prototype?) do
    first_id = Map.get(state, :original_group_id, hd(state.plan.groups).id)
    first? = step.group_id == first_id

    continuation? =
      if state.plan.placement == :independent,
        do: if(prototype?, do: not first?, else: state.answer_reserved?),
        else: state.answer_confirmed? or (prototype? and not first?)

    continuation? and not (files == [] and not state.answer_confirmed? and not prototype?)
  end

  defp answer_pending?(state),
    do:
      not state.answer_confirmed? and
        (state.plan.placement != :independent or not state.answer_reserved?)

  defp publication_inputs(state, step, prototype?) do
    files = publication_files(state, step.group_id)
    continuation? = continuation?(state, step, files, prototype?)

    ordinal = Enum.find_index(state.plan.groups, &(&1.id == step.group_id)) + 1

    body =
      if continuation?,
        do: "Additional files (#{ordinal}/#{length(state.plan.groups)}).",
        else: state.outgoing.body

    thread_id = if state.plan.placement == :threaded, do: state.root

    metadata =
      if continuation?,
        do: Map.drop(state.outgoing.metadata || %{}, [:html_body, "html_body"]),
        else: state.outgoing.metadata

    outgoing = %{
      state.outgoing
      | body: body,
        thread_id: thread_id,
        attachments: [],
        metadata: metadata
    }

    %{
      outgoing: outgoing,
      attachments: files,
      continuation?: continuation?,
      root_message_id: thread_id
    }
  end

  defp skip_empty?(state, step, []),
    do: not answer_pending?(state) or state.fallback_reserved? or later_usable?(state, step)

  defp skip_empty?(_state, _step, _files), do: false

  defp later_usable?(state, step),
    do:
      state.plan.groups
      |> Enum.drop_while(&(&1.id != step.group_id))
      |> Enum.drop(1)
      |> Enum.any?(&(publication_files(state, &1.id) != []))

  defp raw_files(state, group_id) do
    for index <- Map.get(state.usable, group_id, []),
        {:ok, attachment} <- [Map.get(state.preparation.cache, index)],
        do: Map.put(attachment, :index, index)
  end

  defp publication_files(
         %{plan: %{requirements: %{transfer_mode: :upload_then_publish}}} = state,
         group_id
       ) do
    group = Enum.find(state.plan.groups, &(&1.id == group_id))

    for index <- group.attachment_refs,
        {:ok, reference} <- [Map.fetch(state.uploaded, index)],
        do:
          Map.merge(Map.get(state.uploaded_file_metadata, index, %{}), %{
            index: index,
            reference: reference
          })
  end

  defp publication_files(state, group_id), do: raw_files(state, group_id)

  defp dependency_status(step, state) do
    Enum.reduce_while(step.depends_on, :ready, fn id, _ ->
      case dependency_outcome(Map.get(state.results, id), step.operation) do
        :ready -> {:cont, :ready}
        status -> {:halt, status}
      end
    end)
  end

  defp dependency_outcome(nil, _operation), do: :waiting
  defp dependency_outcome(%{operation: :upload, outcome: :uploaded}, _operation), do: :ready
  defp dependency_outcome(%{operation: :upload}, :upload), do: :blocked
  defp dependency_outcome(%{operation: :upload}, _operation), do: :ready
  defp dependency_outcome(%{outcome: :confirmed}, _operation), do: :ready
  defp dependency_outcome(_outcome, _operation), do: :blocked

  defp run_jobs([], _state), do: %{}

  defp run_jobs(jobs, state) do
    state.supervisor
    |> Task.Supervisor.async_stream_nolink(jobs, fn job -> {job.step.id, invoke(job, state)} end,
      ordered: false,
      max_concurrency: state.concurrency,
      timeout: state.timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, {id, outcome}} ->
        {id, outcome}

      {:exit, {%{step: step}, reason}} ->
        code = if reason == :timeout, do: :timeout, else: :unknown
        {step.id, %{outcome: :unconfirmed, error: error(stage(step), :unconfirmed, code, reason)}}
    end)
  end

  defp invoke(job, state) do
    response = state.bridge.execute_delivery_step(job.step, job.inputs, state.connection)
    normalize_response(job, response)
  rescue
    exception ->
      %{outcome: :unconfirmed, error: error(stage(job.step), :unconfirmed, :unknown, exception)}
  catch
    kind, reason ->
      %{
        outcome: :unconfirmed,
        error: error(stage(job.step), :unconfirmed, :unknown, {kind, reason})
      }
  end

  defp normalize_response(%{step: %{operation: :upload}} = job, response),
    do: normalize_upload(job, response)

  defp normalize_response(job, {:ok, %{confirmation: :confirmed, message_id: id} = receipt}) do
    if valid_id?(id),
      do: %{
        outcome: :confirmed,
        receipt:
          Map.put(
            receipt,
            :attachment_refs,
            Map.new(
              for %{index: index, reference: ref} <- job.inputs.attachments, do: {index, ref}
            )
          ),
        publication: %{
          body: job.inputs.outgoing.body,
          thread_id: job.inputs.outgoing.thread_id,
          continuation?: Map.get(job.inputs, :continuation?, false)
        },
        delivered_attachment_refs: Enum.map(job.inputs.attachments, & &1.index),
        delivered_file_metadata: file_metadata(job.inputs.attachments)
      },
      else: uncertain(job.step, receipt)
  end

  defp normalize_response(job, {:error, %Error{} = failure}),
    do: normalized_failure(job.step, failure)

  defp normalize_response(job, response), do: uncertain(job.step, response)

  defp normalize_upload(job, response) do
    {refs, failure} = upload_response(response)
    expected = Enum.map(job.inputs.attachments, & &1.index)
    {refs, malformed?} = usable_upload_refs(refs, expected)

    outcome =
      cond do
        malformed? ->
          Map.put(uncertain(job.step, response), :uploaded_refs, refs)

        failure ->
          Map.put(normalized_failure(job.step, failure), :uploaded_refs, refs)

        MapSet.new(Map.keys(refs)) == MapSet.new(expected) ->
          %{outcome: :uploaded, uploaded_refs: refs}

        true ->
          Map.put(uncertain(job.step, response), :uploaded_refs, refs)
      end

    Map.put(
      outcome,
      :uploaded_file_metadata,
      Map.take(file_metadata(job.inputs.attachments), Map.keys(refs))
    )
  end

  defp file_metadata(attachments) do
    Map.new(attachments, fn file -> {file.index, Map.take(file, [:name, :mime_type, :size])} end)
  end

  defp upload_response({:ok, %{uploaded_refs: refs}}), do: {refs, nil}
  defp upload_response({:error, %Error{} = failure, %{uploaded_refs: refs}}), do: {refs, failure}
  defp upload_response({:error, %Error{} = failure}), do: {%{}, failure}
  defp upload_response(other), do: {%{}, error(:upload, :unconfirmed, :unknown, other)}

  defp usable_upload_refs(refs, expected) when is_map(refs) do
    usable = Map.filter(refs, fn {index, ref} -> index in expected and valid_id?(ref) end)
    {usable, map_size(usable) != map_size(refs)}
  end

  defp usable_upload_refs(_refs, _expected), do: {%{}, true}

  defp normalized_failure(step, failure) do
    failure = %{failure | stage: stage(step)}

    case Error.safe_facts(failure) do
      {:ok, _} -> %{outcome: failure.outcome, error: failure}
      _ -> uncertain(step, failure)
    end
  end

  defp uncertain(step, cause),
    do: %{outcome: :unconfirmed, error: error(stage(step), :unconfirmed, :unknown, cause)}

  defp apply_results(state, jobs, results) do
    Enum.reduce(jobs, state, fn job, state ->
      outcome = Map.fetch!(results, job.step.id)

      state = %{
        state
        | results:
            Map.put(state.results, job.step.id, Map.put(outcome, :operation, job.step.operation)),
          preparation: Preparation.release_step(state.preparation, job.step.id)
      }

      state = %{
        state
        | uploaded: Map.merge(state.uploaded, Map.get(outcome, :uploaded_refs, %{})),
          uploaded_file_metadata:
            Map.merge(
              state.uploaded_file_metadata,
              Map.get(outcome, :uploaded_file_metadata, %{})
            )
      }

      case outcome do
        %{outcome: :confirmed, receipt: receipt} ->
          %{
            state
            | answer_confirmed?: true,
              root: state.root || receipt[:thread_id] || receipt.message_id
          }

        %{error: failure} ->
          %{
            state
            | first_error: state.first_error || failure,
              halted?: state.halted? or abort?(state)
          }

        _ ->
          state
      end
    end)
  end

  defp put_unattempted(state, step, reason) do
    outcome = %{
      outcome: :unattempted,
      operation: step.operation,
      error: error(stage(step), :failed, reason)
    }

    %{
      state
      | results: Map.put_new(state.results, step.id, outcome),
        preparation: Preparation.release_step(state.preparation, step.id)
    }
  end

  defp finish(state) do
    closed = Preparation.close(state.preparation)
    result = Result.new(state.plan, state.results, state.attempt_id, Preparation.failures(closed))
    result = %{result | started_at: state.started_at}
    classify_result(result, state.first_error || first_failure(result))
  end

  defp classify_result(result, failure) do
    if Result.confirmed_receipts(result) != [], do: {:ok, result}, else: {:error, failure, result}
  end

  defp first_failure(result),
    do:
      Enum.find_value(result.failures, & &1.error) ||
        error(:configuration, :failed, :missing_configuration)

  defp abort?(state), do: state.plan.requirements.failure_policy == :abort
  defp stage(%{operation: :upload}), do: :upload
  defp stage(_), do: :publication
  defp valid_id?(id) when is_binary(id), do: id != ""
  defp valid_id?(id), do: is_integer(id) and id > 0

  defp error(stage, outcome, reason, cause \\ nil),
    do: %Error{stage: stage, outcome: outcome, reason: reason, cause: cause}

  defp requirements_failure?(reason) when reason in [:unsupported, :capabilities_unavailable],
    do: true

  defp requirements_failure?({reason, _})
       when reason in [:invalid_configuration, :unresolved_capabilities], do: true

  defp requirements_failure?(_), do: false

  defp execute_text_fallback(outgoing, reason, bridge, connection, opts) do
    failure = error(:configuration, :failed, :missing_configuration, reason)

    failures =
      outgoing.attachments
      |> Enum.with_index()
      |> Enum.map(fn {_, index} -> %{group_id: nil, attachment_refs: [index], error: failure} end)

    result = %Result{
      attempt_id: Keyword.get_lazy(opts, :attempt_id, &Ecto.UUID.generate/0),
      started_at:
        Keyword.get_lazy(opts, :attempt_started_at, fn ->
          DateTime.to_iso8601(DateTime.utc_now())
        end),
      steps: [],
      failures: failures
    }

    with {:ok, :continue} <-
           connection |> FileSettings.from_connection() |> FileSettings.failure_policy(),
         {:ok, runtime} <-
           runtime(
             outgoing,
             nil,
             bridge,
             connection,
             Keyword.put(opts, :attempt_id, result.attempt_id)
           ),
         {:ok, limit} <- Keyword.fetch(opts, :max_text_request_bytes) do
      send_text_fallback(runtime, result, limit)
    else
      _ -> {:error, failure, result}
    end
  end

  defp send_text_fallback(runtime, result, limit) do
    step = text_fallback_step(runtime)
    outgoing = %{runtime.outgoing | attachments: []}
    inputs = %{outgoing: outgoing, attachments: [], continuation?: false}

    with {:ok, prepared} <- prepare_text(runtime.bridge, outgoing, runtime.connection),
         :ok <- Preparation.validate_request(prepared, limit) do
      job = %{step: step, inputs: Map.put(inputs, :prepared, prepared)}
      outcome = Map.fetch!(run_jobs([job], runtime), step.id)
      result = %{result | steps: [Map.put(outcome, :step, step)]}
      classify_result(result, Map.get(outcome, :error, first_failure(result)))
    else
      reason -> {:error, error(:preparation, :failed, :preparation_failed, reason), result}
    end
  end

  defp text_fallback_step(runtime) do
    metadata = runtime.outgoing.metadata || %{}

    id =
      ConversationIdentity.normalize(
        Map.get(metadata, :message_id) || Map.get(metadata, "message_id")
      )

    if runtime.text_edits? and is_binary(id) and id != "",
      do: %Step{id: {:edit, 0}, operation: :edit, group_id: 0, message_ref: {:existing, id}},
      else: %Step{id: {:send, 0}, operation: :send, group_id: 0}
  end

  defp prepare_text(bridge, outgoing, connection) do
    bridge.prepare_delivery_message(outgoing, [], connection)
  rescue
    _ -> {:error, :text_preparation_exception}
  catch
    _, _ -> {:error, :text_preparation_exit}
  end
end
