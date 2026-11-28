defmodule Zaq.Engine.Conversations.MessageDelivery do
  @moduledoc """
  Private delivery observations for persisted agent answers.

  Engine validates the exact stored input/answer and origin before recording
  bounded transport facts. Confirmation remains authoritative. These writes
  neither place messages in transcripts nor schedule transport delivery.
  Eligibility composes `AnswerOwnership` relationships with delivery-specific reply
  and origin checks; neither grants permission to read a transcript.

  Terminal snapshots are immutable per attempt. Explicit UTC start times select
  current presentation under the answer row lock; earlier evidence stays private
  in attempt history. Equal or missing times never displace a dated current attempt.
  """

  import Ecto.Query

  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations.DeliveryEvidence

  alias Zaq.Engine.Conversations.{
    AnswerOwnership,
    Message,
    Transcript,
    TranscriptMessage
  }

  alias Zaq.Repo

  @reasons [:rejected, :missing_configuration, :unsupported_provider, :timeout, :unknown]

  @doc "Records allowlisted transport evidence without altering content or confirmed delivery."
  def record(request, opts \\ [])

  def record(%{delivery_parts: evidence} = request, opts) do
    with {:ok, input} <- Ecto.UUID.cast(request[:user_message_id]),
         {:ok, answer} <- Ecto.UUID.cast(request[:assistant_message_id]),
         config when is_integer(config) and config > 0 <- request[:channel_config_id],
         {:ok, safe} <- DeliveryEvidence.normalize(evidence) do
      result =
        Repo.transaction(fn ->
          record_for_origin(input, answer, config, %{delivery_parts: safe})
        end)

      if result == {:ok, :recorded}, do: ChannelHistoryUpdates.publish([answer], opts)
      result
    else
      _ -> {:error, :invalid_delivery_observation}
    end
  end

  def record(%{outcome: outcome, reason: reason} = request, opts)
      when outcome in [:failed, :unconfirmed] and reason in @reasons do
    with {:ok, input_id} <- Ecto.UUID.cast(request[:user_message_id]),
         {:ok, answer_id} <- Ecto.UUID.cast(request[:assistant_message_id]),
         id when is_integer(id) and id > 0 <- request[:channel_config_id],
         true <- valid_provider_code?(request[:provider_code]),
         true <-
           outcome != :failed or
             reason in [:rejected, :missing_configuration, :unsupported_provider] do
      result =
        Repo.transaction(fn -> record_for_origin(input_id, answer_id, id, request) end)

      if result == {:ok, :recorded}, do: ChannelHistoryUpdates.publish([answer_id], opts)
      result
    else
      _ -> {:error, :invalid_delivery_observation}
    end
  end

  def record(_request, _opts), do: {:error, :invalid_delivery_observation}

  @doc "Checks exact completed-answer origin scope for Engine confirmation owners."
  def valid_scope?(input_id, answer_id, config_id) do
    with {:ok, input} <- Ecto.UUID.cast(input_id),
         {:ok, answer} <- Ecto.UUID.cast(answer_id),
         true <- is_integer(config_id) and config_id > 0 do
      valid_origin?(input, answer, config_id)
    else
      _ -> false
    end
  end

  @doc "Builds an internal exact-answer query; callers must authorize their read scope."
  def answers_query do
    completed_roots =
      AnswerOwnership.owned_root_executions_query()
      |> where([execution: execution], execution.status == "completed")
      |> where(
        [execution: execution, answer: answer],
        execution.id == parent_as(:execution).id and answer.id == parent_as(:answer).id
      )
      |> select([execution: execution], execution.id)

    AnswerOwnership.conversation_pairs_query()
    |> where(
      [answer: answer, input: input],
      fragment("?->>'in_reply_to_message_id' = ?::text", answer.metadata, input.id)
    )
    |> join(:left, [input: input], execution in subquery(AnswerOwnership.root_executions_query()),
      as: :execution,
      on: execution.user_message_id == input.id
    )
    |> where(
      [answer: answer, input: input, execution: execution],
      (is_nil(execution.id) and
         fragment("?->>'execution_status' = 'completed'", input.metadata)) or
        exists(subquery(completed_roots))
    )
  end

  @doc "Restricts answers to exact origin placements, including safely scoped legacy origins."
  def origin_query(transcript_id) do
    answers_query()
    |> with_origin()
    |> where([transcript: transcript], transcript.id == ^transcript_id)
  end

  defp with_origin(query) do
    query
    |> join(:inner, [input: input], placement in TranscriptMessage,
      as: :origin_placement,
      on: placement.message_id == input.id
    )
    |> join(:inner, [origin_placement: placement], transcript in Transcript,
      as: :transcript,
      on: transcript.id == placement.transcript_id
    )
    |> where(
      [input: input, conversation: conversation, transcript: transcript],
      conversation.channel_type == transcript.provider and
        (conversation.channel_config_id == transcript.channel_config_id or
           (is_nil(conversation.channel_config_id) and
              fragment(
                "?->'history_source'->>'channel_config_id' = ?::text",
                input.metadata,
                transcript.channel_config_id
              )))
    )
  end

  @doc "Returns safe UI facts, never raw provider errors or private execution metadata."
  def presentation(%{metadata: metadata}) do
    observation = metadata["delivery_observation"] || %{}

    parts =
      case DeliveryEvidence.normalize(metadata["delivery_parts"]) do
        {:ok, safe} -> safe
        _ -> %{}
      end

    state = delivery_state(metadata, observation, parts)
    observation = if parts == %{}, do: observation, else: %{}

    %{
      state: state,
      reason: explanation(state, observation["reason_code"]),
      provider_code: if(state != :history_updating, do: observation["provider_code"]),
      observed_at: if(state != :history_updating, do: observation["observed_at"]),
      parts: Map.get(parts, "parts", []),
      omitted_part_count: Map.get(parts, "omitted_part_count", 0)
    }
  end

  defp delivery_state(metadata, _observation, %{"confirmed_message_count" => count} = evidence) do
    parts = evidence["parts"]

    cond do
      count > 0 and is_map(metadata["delivery_confirmation"]) ->
        if parts == [] and evidence["omitted_part_count"] == 0,
          do: :history_updating,
          else: :partial

      parts != [] and Enum.all?(parts, &(&1["outcome"] in ["failed", "unattempted"])) ->
        :failed

      true ->
        :unconfirmed
    end
  end

  defp delivery_state(metadata, observation, _parts) do
    cond do
      is_map(metadata["delivery_confirmation"]) ->
        :history_updating

      observation["outcome"] == "failed" ->
        :failed

      true ->
        :unconfirmed
    end
  end

  defp valid_origin?(input_id, answer_id, config_id) do
    answers_query()
    |> with_origin()
    |> where(
      [answer: answer, input: input, conversation: conversation, transcript: transcript],
      answer.id == ^answer_id and input.id == ^input_id and
        transcript.channel_config_id == ^config_id and
        conversation.channel_type == transcript.provider
    )
    |> Repo.exists?()
  end

  defp record_for_origin(input_id, answer_id, config_id, request) do
    answer = Repo.one(from m in Message, where: m.id == ^answer_id, lock: "FOR UPDATE")

    unless answer && valid_origin?(input_id, answer_id, config_id) do
      Repo.rollback(:invalid_delivery_scope)
    end

    record_locked(answer, request)
  end

  defp record_locked(answer, %{delivery_parts: parts}) do
    current = answer.metadata["delivery_parts"] || %{}
    attempts = answer.metadata["delivery_attempts"] || %{}

    previous =
      attempts[parts["attempt_id"]] ||
        if(current["attempt_id"] == parts["attempt_id"], do: current)

    if previous do
      :unchanged
    else
      parts = Map.put(parts, "observed_at", DateTime.to_iso8601(DateTime.utc_now()))

      attempts =
        if current == %{},
          do: attempts,
          else: Map.put_new(attempts, current["attempt_id"], current)

      metadata =
        Map.put(
          answer.metadata,
          "delivery_attempts",
          Map.put(attempts, parts["attempt_id"], parts)
        )

      metadata =
        if newer_attempt?(parts, current),
          do: Map.put(metadata, "delivery_parts", parts),
          else: metadata

      answer
      |> Message.confirmation_changeset(metadata)
      |> Repo.update!()

      :recorded
    end
  end

  defp record_locked(answer, %{outcome: outcome, reason: reason} = request) do
    previous = answer.metadata["delivery_observation"] || %{}

    cond do
      is_map(answer.metadata["delivery_confirmation"]) ->
        :confirmed

      previous["outcome"] == to_string(outcome) and previous["reason_code"] == to_string(reason) and
          previous["provider_code"] == request[:provider_code] ->
        :unchanged

      true ->
        observation = %{
          "version" => 1,
          "outcome" => to_string(outcome),
          "reason_code" => to_string(reason),
          "provider_code" => request[:provider_code],
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        answer
        |> Message.confirmation_changeset(
          Map.put(answer.metadata, "delivery_observation", observation)
        )
        |> Repo.update!()

        :recorded
    end
  end

  defp newer_attempt?(_parts, current) when current == %{}, do: true

  defp newer_attempt?(parts, current) do
    with started_at when is_binary(started_at) <- parts["started_at"],
         {:ok, incoming, 0} <- DateTime.from_iso8601(started_at),
         previous_at when is_binary(previous_at) <- current["started_at"],
         {:ok, previous, 0} <- DateTime.from_iso8601(previous_at) do
      DateTime.compare(incoming, previous) == :gt
    else
      _ -> is_binary(parts["started_at"]) and is_nil(current["started_at"])
    end
  end

  defp valid_provider_code?(nil), do: true
  defp valid_provider_code?(code), do: is_integer(code) and code >= 0 and code <= 999

  defp explanation(:history_updating, _),
    do: "Delivery was confirmed. Transcript history is updating."

  defp explanation(:partial, _), do: "Some delivery parts failed or remain unconfirmed."

  defp explanation(:failed, "rejected"), do: "The provider rejected the delivery."

  defp explanation(:failed, "missing_configuration"),
    do: "The connector was unavailable before sending."

  defp explanation(:failed, "unsupported_provider"),
    do: "No supported delivery adapter was available."

  defp explanation(:failed, _), do: "The delivery attempt failed."

  defp explanation(:unconfirmed, "timeout"),
    do: "The delivery timed out. The provider may have accepted the message."

  defp explanation(:unconfirmed, _),
    do: "No definitive delivery outcome is recorded. The message may have been delivered."
end
