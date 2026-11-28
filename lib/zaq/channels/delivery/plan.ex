defmodule Zaq.Channels.Delivery.Plan do
  @moduledoc """
  Internal metadata decisions for a Channel attachment delivery attempt.

  Groups and steps reference original indices in `Outgoing.attachments`. Records,
  acquired bytes, prepared requests and execution outcomes remain outside the plan.
  Requirements retain unresolved limits; a plan does not attest provider acceptance
  or actual content size. Execution must validate acquired content and requests.
  """

  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements

  @enforce_keys [:requirements, :placement, :groups, :steps]
  @derive {Inspect, only: [:placement]}
  defstruct [:requirements, :placement, :groups, :steps]

  @type group :: %{id: non_neg_integer(), attachment_refs: [non_neg_integer()]}
  @type t :: %__MODULE__{
          requirements: TransportRequirements.t(),
          placement: :threaded | :independent,
          groups: [group()],
          steps: [Step.t()]
        }

  @doc """
  Validates fixed groups, original indices and an acyclic dependency graph before effects.

  This checks metadata structure, including upload dependencies and explicit edit
  support. Requirements and acquired/request sizes still need their existing
  `Attachments` validations. It does not acquire content or select failure policy.
  """
  @spec validate(t(), non_neg_integer()) :: :ok | {:error, :invalid_delivery_plan}
  def validate(%__MODULE__{} = plan, attachment_count)
      when is_integer(attachment_count) and attachment_count >= 0 do
    with true <- plan.placement in [:threaded, :independent],
         %TransportRequirements{} <- plan.requirements,
         true <- valid_groups?(plan.groups, attachment_count),
         true <- valid_steps?(plan),
         true <- valid_dependencies?(plan.steps),
         true <- acyclic?(plan.steps) do
      :ok
    else
      _ -> {:error, :invalid_delivery_plan}
    end
  end

  def validate(_plan, _attachment_count), do: {:error, :invalid_delivery_plan}

  defp valid_groups?(groups, count) when is_list(groups) do
    Enum.all?(groups, fn
      %{id: id, attachment_refs: refs} ->
        is_integer(id) and id >= 0 and valid_refs?(refs) and
          (refs != [] or (count == 0 and length(groups) == 1))

      _ ->
        false
    end) and unique?(Enum.map(groups, & &1.id)) and
      Enum.sort(Enum.flat_map(groups, & &1.attachment_refs)) == indices(count)
  end

  defp valid_groups?(_groups, _count), do: false

  defp valid_steps?(%{steps: steps} = plan) when is_list(steps) do
    groups = Map.new(plan.groups, &{&1.id, &1.attachment_refs})

    Enum.all?(steps, &valid_step?(&1, groups, plan.requirements)) and
      unique?(Enum.map(steps, & &1.id)) and
      Enum.all?(plan.groups, &valid_group_steps?(&1, steps, plan.requirements.transfer_mode))
  end

  defp valid_steps?(_plan), do: false

  defp valid_step?(%Step{} = step, groups, requirements) do
    with {:ok, _reference} <- Step.reference(step),
         {:ok, group_refs} <- Map.fetch(groups, step.group_id),
         true <- valid_refs?(step.attachment_refs),
         true <- is_list(step.depends_on) and unique?(step.depends_on) do
      valid_intent?(step, group_refs, requirements)
    else
      _ -> false
    end
  end

  defp valid_step?(_step, _groups, _requirements), do: false

  defp valid_intent?(%Step{operation: :upload} = step, refs, requirements),
    do:
      requirements.transfer_mode == :upload_then_publish and is_nil(step.message_ref) and
        step.attachment_refs != [] and Enum.all?(step.attachment_refs, &(&1 in refs))

  defp valid_intent?(%Step{operation: :send} = step, refs, _requirements),
    do: step.attachment_refs == refs and is_nil(step.message_ref)

  defp valid_intent?(
         %Step{operation: :edit, message_ref: {:existing, id}} = step,
         refs,
         requirements
       ),
       do:
         requirements.supports_attachment_edits == true and is_binary(id) and id != "" and
           step.attachment_refs == refs

  defp valid_intent?(_step, _refs, _requirements), do: false

  defp valid_group_steps?(group, steps, mode) do
    group_steps = Enum.filter(steps, &(&1.group_id == group.id))
    {uploads, publications} = Enum.split_with(group_steps, &(&1.operation == :upload))

    case publications do
      [publication] ->
        upload_refs = Enum.flat_map(uploads, & &1.attachment_refs)

        valid_uploads? =
          case mode do
            :upload_then_publish -> Enum.sort(upload_refs) == Enum.sort(group.attachment_refs)
            :send_with_attachments -> uploads == []
            _ -> false
          end

        valid_uploads? and Enum.all?(uploads, &(&1.id in publication.depends_on))

      _ ->
        false
    end
  end

  defp valid_dependencies?(steps) do
    ids = MapSet.new(steps, & &1.id)
    Enum.all?(steps, fn step -> Enum.all?(step.depends_on, &MapSet.member?(ids, &1)) end)
  end

  defp acyclic?([]), do: true

  defp acyclic?(steps) do
    {ready, pending} = Enum.split_with(steps, &(&1.depends_on == []))

    if ready == [] do
      false
    else
      ids = MapSet.new(ready, & &1.id)

      pending =
        Enum.map(
          pending,
          &%{&1 | depends_on: Enum.reject(&1.depends_on, fn id -> MapSet.member?(ids, id) end)}
        )

      acyclic?(pending)
    end
  end

  defp valid_refs?(refs) when is_list(refs),
    do: Enum.all?(refs, &(is_integer(&1) and &1 >= 0)) and unique?(refs)

  defp valid_refs?(_refs), do: false
  defp unique?(values), do: MapSet.size(MapSet.new(values)) == length(values)
  defp indices(0), do: []
  defp indices(count), do: Enum.to_list(0..(count - 1))
end
