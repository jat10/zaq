defmodule Zaq.Engine.Conversations.DeliveryEvidence do
  @moduledoc "Validates bounded transport evidence before Engine stores or projects it."

  @failed_reasons [
    :rejected,
    :missing_configuration,
    :unsupported_provider,
    :invalid_plan,
    :invalid_attachment,
    :content_unavailable,
    :preparation_failed,
    :size_limit,
    :dependency_failed,
    :aborted
  ]
  @stages [:configuration, :preparation, :upload, :publication]
  @operations [:upload, :send, :edit, :configure, :prepare]

  @doc "Validates a publication's attempt/group identity without granting answer ownership."
  def reference(%{attempt_id: attempt, group_id: group, primary?: primary})
      when is_integer(group) and group >= 0 and is_boolean(primary) do
    case Ecto.UUID.cast(attempt) do
      {:ok, uuid} -> {:ok, %{attempt_id: uuid, group_id: group, primary?: primary}}
      _ -> {:error, :invalid_delivery_evidence}
    end
  end

  def reference(_), do: {:error, :invalid_delivery_evidence}

  @doc "Returns content-free JSON facts; unknown fields never cross persistence."
  def normalize(
        %{
          version: 1,
          attempt_id: attempt,
          parts: parts,
          confirmed_message_count: messages,
          confirmed_attachment_count: attachments,
          omitted_part_count: omitted
        } = evidence
      )
      when is_list(parts) and length(parts) <= 128 do
    with {:ok, uuid} <- Ecto.UUID.cast(attempt),
         {:ok, started_at} <- normalize_start(evidence[:started_at]),
         true <- Enum.all?([messages, attachments, omitted], &count?/1),
         true <- Enum.all?(parts, &valid_part?/1) do
      safe = %{
        version: 1,
        attempt_id: uuid,
        started_at: started_at,
        confirmed_message_count: messages,
        confirmed_attachment_count: attachments,
        omitted_part_count: omitted,
        parts:
          Enum.map(
            parts,
            &Map.take(&1, [
              :step_id,
              :group_id,
              :operation,
              :stage,
              :outcome,
              :reason,
              :provider_code,
              :attachment_refs,
              :omitted_attachment_count
            ])
          )
      }

      {:ok, safe |> Jason.encode!() |> Jason.decode!()}
    else
      _ -> {:error, :invalid_delivery_evidence}
    end
  end

  def normalize(%{"version" => 1, "parts" => parts} = stored) when is_list(parts) do
    normalize(%{
      version: 1,
      attempt_id: stored["attempt_id"],
      started_at: stored["started_at"],
      parts: Enum.map(parts, &stored_part/1),
      confirmed_message_count: stored["confirmed_message_count"],
      confirmed_attachment_count: stored["confirmed_attachment_count"],
      omitted_part_count: stored["omitted_part_count"]
    })
  end

  def normalize(_), do: {:error, :invalid_delivery_evidence}

  defp normalize_start(nil), do: {:ok, nil}

  defp normalize_start(value) when is_binary(value) and byte_size(value) <= 32 do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()}
      _ -> {:error, :invalid_delivery_evidence}
    end
  end

  defp normalize_start(_), do: {:error, :invalid_delivery_evidence}

  defp stored_part(part) when is_map(part) do
    %{
      step_id: stored_step(part["step_id"]),
      group_id: part["group_id"],
      operation: known_atom(part["operation"], @operations),
      stage: known_atom(part["stage"], @stages),
      outcome: known_atom(part["outcome"], [:failed, :unconfirmed, :unattempted]),
      reason: known_atom(part["reason"], @failed_reasons ++ [:timeout, :unknown]),
      attachment_refs: part["attachment_refs"],
      omitted_attachment_count: part["omitted_attachment_count"],
      provider_code: part["provider_code"]
    }
  end

  defp stored_part(_), do: nil
  defp stored_step([operation | refs]), do: [known_atom(operation, @operations) | refs]
  defp stored_step(_), do: nil
  defp known_atom(value, allowed), do: Enum.find(allowed, &(to_string(&1) == value))

  defp valid_part?(
         %{
           step_id: step,
           group_id: group,
           operation: operation,
           stage: stage,
           outcome: outcome,
           reason: reason,
           attachment_refs: refs,
           omitted_attachment_count: omitted
         } = part
       ) do
    operation in @operations and stage in @stages and valid_outcome?(outcome, reason, stage) and
      (is_nil(group) or count?(group)) and valid_step?(step, operation, group) and
      valid_refs?(refs) and
      count?(omitted) and valid_code?(part[:provider_code])
  end

  defp valid_part?(_), do: false

  defp valid_outcome?(:failed, reason, _), do: reason in @failed_reasons

  defp valid_outcome?(:unconfirmed, reason, stage),
    do: stage in [:upload, :publication] and reason in [:timeout, :unknown]

  defp valid_outcome?(:unattempted, reason, _), do: reason in @failed_reasons
  defp valid_outcome?(_, _, _), do: false

  defp valid_step?(nil, operation, _), do: operation in [:configure, :prepare]
  defp valid_step?([:upload, group, batch], :upload, group), do: count?(group) and count?(batch)

  defp valid_step?([operation, group], operation, group),
    do: operation in [:send, :edit] and count?(group)

  defp valid_step?(_, _, _), do: false

  defp valid_refs?(refs) when is_list(refs) and length(refs) <= 128,
    do: Enum.all?(refs, &count?/1) and length(Enum.uniq(refs)) == length(refs)

  defp valid_refs?(_), do: false
  defp count?(value), do: is_integer(value) and value in 0..2_147_483_647
  defp valid_code?(nil), do: true
  defp valid_code?(value), do: is_integer(value) and value in 0..999
end
