defmodule Zaq.Channels.Delivery.Result do
  @moduledoc """
  Private, ordered outcomes for one Channel delivery attempt.

  Executor inputs remain separate: Outgoing, metadata Plan, selected connection
  and trusted runtime dependencies. Results retain confirmed publication receipts,
  actual delivered indices, uploaded-only references and unsuccessful facts.
  Uploads never confirm publication; a text fallback never confirms discarded files.

  `safe_evidence/1` projects bounded failure facts without receipts, provider file
  references, causes, content or plans. DeliveryConfirmation attaches the persisted input/answer
  and origin connector identifiers; Engine validates their ownership and scope.
  Reporting failure must never cause provider effects to be repeated.
  `started_at` carries the UTC attempt start captured before preparation, including
  when the terminal report has no unsuccessful parts. Undated legacy results remain valid.
  """

  alias Zaq.Channels.Delivery.{Error, Plan}
  alias Zaq.Channels.Delivery.Plan.Step

  @enforce_keys [:attempt_id, :steps]
  @derive {Inspect, only: [:attempt_id]}
  defstruct [:attempt_id, :started_at, :steps, failures: []]

  @type step_result :: %{
          required(:step) => Step.t(),
          required(:outcome) => :confirmed | :uploaded | :failed | :unconfirmed | :unattempted,
          optional(:receipt) => map(),
          optional(:delivered_attachment_refs) => [non_neg_integer()],
          optional(:uploaded_refs) => map(),
          optional(:publication) => %{
            body: String.t(),
            thread_id: String.t() | nil,
            continuation?: boolean()
          },
          optional(:uploaded_file_metadata) => %{non_neg_integer() => map()},
          optional(:delivered_file_metadata) => %{non_neg_integer() => map()},
          optional(:error) => Error.t()
        }
  @type failure :: %{
          group_id: non_neg_integer() | nil,
          attachment_refs: [non_neg_integer()],
          error: Error.t()
        }
  @type t :: %__MODULE__{
          attempt_id: Ecto.UUID.t(),
          started_at: String.t() | nil,
          steps: [step_result()],
          failures: [failure()]
        }
  @type part :: %{
          optional(:provider_code) => 0..999,
          step_id: [atom() | non_neg_integer()] | nil,
          group_id: non_neg_integer() | nil,
          operation: :upload | :send | :edit | :configure | :prepare,
          attachment_refs: [non_neg_integer()],
          omitted_attachment_count: non_neg_integer(),
          stage: Error.stage(),
          outcome: :failed | :unconfirmed | :unattempted,
          reason: Error.reason()
        }
  @type evidence :: %{
          version: 1,
          attempt_id: Ecto.UUID.t(),
          started_at: String.t() | nil,
          confirmed_message_count: non_neg_integer(),
          confirmed_attachment_count: non_neg_integer(),
          parts: [part()],
          omitted_part_count: non_neg_integer()
        }

  @part_limit 128
  @ref_limit 128

  @doc "Builds plan-ordered outcomes from completed steps; absent steps remain unattempted."
  @spec new(Plan.t(), map(), Ecto.UUID.t(), [failure()]) :: t()
  def new(%Plan{} = plan, outcomes, attempt_id, failures \\ []) do
    steps =
      Enum.map(plan.steps, fn step ->
        facts = Map.get(outcomes, step.id, %{outcome: :unattempted})

        facts
        |> Map.take([
          :outcome,
          :receipt,
          :delivered_attachment_refs,
          :uploaded_refs,
          :error,
          :publication,
          :uploaded_file_metadata,
          :delivered_file_metadata
        ])
        |> Map.put(:step, step)
      end)

    %__MODULE__{attempt_id: attempt_id, steps: steps, failures: failures}
  end

  @doc "Returns only explicitly confirmed send/edit receipts, in plan order."
  @spec confirmed_receipts(t()) :: [map()]
  def confirmed_receipts(%__MODULE__{steps: steps}) do
    for %{
          step: %Step{operation: operation},
          outcome: :confirmed,
          receipt: %{confirmation: :confirmed} = receipt
        } <- steps,
        operation in [:send, :edit],
        do: receipt
  end

  @doc """
  Returns v1 Engine facts or rejects malformed evidence.

  At most 128 unsuccessful parts and 128 original indices per part cross this
  boundary. Explicit omitted counts preserve truncation; private results retain
  all facts. Successful messages use their normal confirmation/history path.
  """
  @spec safe_evidence(t()) :: {:ok, evidence()} | {:error, :invalid_delivery_result}
  def safe_evidence(%__MODULE__{steps: steps, failures: failures} = result)
      when is_list(steps) and is_list(failures) do
    with {:ok, attempt_id} <- Ecto.UUID.cast(result.attempt_id),
         true <- valid_start?(result.started_at),
         {:ok, step_facts} <- collect(steps, &step_facts/1),
         {:ok, failure_facts} <- collect(failures, &failure_facts/1) do
      parts =
        (failure_facts ++ Enum.flat_map(step_facts, & &1.parts))
        |> Enum.sort_by(&(&1.group_id || -1))

      {:ok,
       %{
         version: 1,
         attempt_id: attempt_id,
         started_at: result.started_at,
         confirmed_message_count: Enum.count(step_facts, & &1.confirmed?),
         confirmed_attachment_count:
           step_facts |> Enum.flat_map(& &1.delivered_refs) |> Enum.uniq() |> length(),
         parts: parts |> Enum.take(@part_limit) |> Enum.map(&bound_refs/1),
         omitted_part_count: max(length(parts) - @part_limit, 0)
       }}
    else
      _ -> {:error, :invalid_delivery_result}
    end
  end

  def safe_evidence(_result), do: {:error, :invalid_delivery_result}

  defp valid_start?(nil), do: true

  defp valid_start?(value) when is_binary(value) and byte_size(value) <= 32 do
    match?({:ok, _, 0}, DateTime.from_iso8601(value))
  end

  defp valid_start?(_), do: false

  defp step_facts(%{step: %Step{} = step} = facts) do
    with {:ok, reference} <- Step.reference(step),
         true <- valid_refs?(step.attachment_refs) do
      project_step(facts, reference)
    else
      _ -> {:error, :invalid_step_result}
    end
  end

  defp step_facts(_facts), do: {:error, :invalid_step_result}

  defp project_step(
         %{
           step: %Step{operation: operation} = step,
           outcome: :confirmed,
           receipt: %{confirmation: :confirmed}
         } = facts,
         _reference
       )
       when operation in [:send, :edit] do
    refs = Map.get(facts, :delivered_attachment_refs, [])

    if valid_refs?(refs) and Enum.all?(refs, &(&1 in step.attachment_refs)),
      do: {:ok, %{confirmed?: true, delivered_refs: refs, parts: []}},
      else: {:error, :invalid_confirmed_refs}
  end

  defp project_step(
         %{step: %Step{operation: :upload}, outcome: :uploaded, uploaded_refs: refs} = facts,
         _reference
       )
       when is_map(refs) and map_size(refs) > 0 do
    if valid_upload_facts?(facts),
      do: {:ok, %{confirmed?: false, delivered_refs: [], parts: []}},
      else: {:error, :invalid_uploaded_refs}
  end

  defp project_step(%{outcome: :unattempted} = facts, reference) do
    step = facts.step

    error =
      Map.get(facts, :error, %Error{
        stage: if(step.operation == :upload, do: :upload, else: :publication),
        outcome: :failed,
        reason: :aborted
      })

    case error do
      %Error{outcome: :failed, reason: reason} when reason in [:aborted, :dependency_failed] ->
        unsuccessful_step(facts, reference, error, :unattempted)

      _ ->
        {:error, :invalid_unattempted_step}
    end
  end

  defp project_step(
         %{outcome: outcome, error: %Error{outcome: outcome} = error} = facts,
         reference
       )
       when outcome in [:failed, :unconfirmed],
       do: unsuccessful_step(facts, reference, error, outcome)

  defp project_step(_facts, _reference), do: {:error, :invalid_step_result}

  defp unsuccessful_step(facts, reference, error, outcome) do
    with {:ok, safe_error} <- Error.safe_facts(error),
         true <- valid_upload_facts?(facts) do
      part =
        Map.merge(safe_error, %{
          step_id: reference,
          group_id: facts.step.group_id,
          operation: facts.step.operation,
          attachment_refs: unsuccessful_refs(facts),
          outcome: outcome
        })

      parts =
        if facts.step.operation == :upload and part.attachment_refs == [], do: [], else: [part]

      {:ok, %{confirmed?: false, delivered_refs: [], parts: parts}}
    else
      _ -> {:error, :invalid_step_result}
    end
  end

  defp valid_upload_facts?(%{step: %Step{operation: :upload}, outcome: :unattempted} = facts),
    do: Map.get(facts, :uploaded_refs, %{}) == %{}

  defp valid_upload_facts?(%{step: %Step{operation: :upload} = step} = facts) do
    case Map.get(facts, :uploaded_refs, %{}) do
      refs when is_map(refs) ->
        Enum.all?(refs, fn {index, id} -> index in step.attachment_refs and provider_id?(id) end)

      _ ->
        false
    end
  end

  defp valid_upload_facts?(_facts), do: true
  defp provider_id?(id) when is_binary(id), do: id != ""
  defp provider_id?(id), do: is_integer(id) and id > 0

  defp unsuccessful_refs(%{step: %Step{operation: :upload} = step, uploaded_refs: refs})
       when is_map(refs),
       do: Enum.reject(step.attachment_refs, &Map.has_key?(refs, &1))

  defp unsuccessful_refs(facts), do: facts.step.attachment_refs

  defp failure_facts(%{
         group_id: group,
         attachment_refs: refs,
         error: %Error{stage: stage} = error
       })
       when stage in [:configuration, :preparation] do
    with true <- is_nil(group) or (is_integer(group) and group in 0..2_147_483_647),
         true <- valid_refs?(refs),
         {:ok, safe_error} <- Error.safe_facts(error) do
      {:ok,
       Map.merge(safe_error, %{
         step_id: nil,
         group_id: group,
         operation: if(error.stage == :configuration, do: :configure, else: :prepare),
         attachment_refs: refs
       })}
    else
      _ -> {:error, :invalid_failure}
    end
  end

  defp failure_facts(_failure), do: {:error, :invalid_failure}

  defp collect(values, projection) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, accumulated} ->
      case projection.(value) do
        {:ok, facts} -> {:cont, {:ok, [facts | accumulated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp bound_refs(part) do
    part
    |> Map.put(:attachment_refs, Enum.take(part.attachment_refs, @ref_limit))
    |> Map.put(:omitted_attachment_count, max(length(part.attachment_refs) - @ref_limit, 0))
  end

  defp valid_refs?(refs) when is_list(refs),
    do:
      Enum.all?(refs, &(is_integer(&1) and &1 in 0..2_147_483_647)) and
        MapSet.size(MapSet.new(refs)) == length(refs)

  defp valid_refs?(_refs), do: false
end
