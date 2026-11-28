defmodule Zaq.Channels.DeliveryConfirmation do
  @moduledoc """
  Reports normalized transport confirmations and unsuccessful outcomes to Engine.

  Transport success is preserved even if the downstream consumer is unavailable;
  reporting a receipt must never cause the accepted message to be resent.
  Bridges and Channels preflight operations supply bounded unsuccessful evidence;
  this reporter never interprets provider errors or selects a transport policy.
  """

  alias Zaq.Channels.Delivery.Result
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  @reasons [:rejected, :missing_configuration, :unsupported_provider, :timeout, :unknown]

  @doc "Reports confirmed messages individually and one bounded failure group; returns transport facts unchanged."
  def record_attempt(response, outgoing, opts) do
    result =
      case response do
        {:ok, %Result{} = result} -> result
        {:error, _, %Result{} = result} -> result
        _ -> nil
      end

    with {:ok, evidence} <- Result.safe_evidence(result) do
      for %{outcome: :confirmed, receipt: receipt} = part <- result.steps do
        {receipt, delivered} = confirmed_part(receipt, part, result.attempt_id, outgoing)
        record({:ok, receipt}, delivered, opts)
      end

      if evidence.parts != [] or evidence.omitted_part_count > 0,
        do: report_observation(%{delivery_parts: evidence}, outgoing, opts)
    end

    response
  end

  defp confirmed_part(receipt, part, attempt_id, outgoing) do
    publication = Map.get(part, :publication, %{})
    continuation? = publication[:continuation?] == true
    metadata = outgoing.metadata || %{}

    answer_id =
      Map.get(metadata, :persisted_assistant_message_id, metadata[:assistant_message_id])

    metadata =
      metadata
      |> Map.take([:user_message_id, :persisted_assistant_message_id])
      |> Map.put(:assistant_message_id, answer_id)

    delivered = %{
      outgoing
      | attachments: [],
        metadata: metadata,
        thread_anchor: nil,
        routing_context:
          Map.take(outgoing.routing_context || %{}, [
            :channel_config_id,
            :conversation_type,
            :source_scope,
            :conversation_id,
            :audience
          ]),
        body: if(continuation?, do: publication.body, else: outgoing.body),
        thread_id: Map.get(publication, :thread_id, receipt[:thread_id])
    }

    receipt =
      receipt
      |> Map.take([
        :confirmation,
        :message_id,
        :thread_id,
        :action,
        :source_scope,
        :conversation_id,
        :audience
      ])
      |> Map.put(:delivery_part, %{
        attempt_id: attempt_id,
        group_id: part.step.group_id,
        primary?: not continuation?
      })
      |> Map.put(:attachments, confirmed_attachments(outgoing, part))
      |> Map.update(:audience, nil, &Audience.normalize/1)

    {receipt, delivered}
  end

  defp confirmed_attachments(outgoing, part) do
    refs = Map.get(part.receipt, :attachment_refs, %{})

    for index <- Enum.take(Map.get(part, :delivered_attachment_refs, []), 128),
        record = Enum.at(outgoing.attachments, index),
        not is_nil(record) do
      descriptor = record |> Record.attachment_metadata() |> Map.drop(["id", "attributes"])

      actual =
        Map.get(Map.get(part, :delivered_file_metadata, %{}), index, %{})
        |> Map.put(:kind, :file)
        |> Record.attachment_metadata()

      descriptor = Map.merge(descriptor, actual)

      case refs[index] do
        id when is_binary(id) and byte_size(id) in 1..4096 -> Map.put(descriptor, "id", id)
        _ -> descriptor
      end
    end
  end

  @doc """
  Forwards a confirmed receipt and its original outgoing message to Engine.
  Errors without normalized evidence remain unconfirmed; use `record/4` to supply it.
  """
  def record({:ok, %{confirmation: :confirmed} = receipt}, outgoing, opts) do
    router = Keyword.get(opts, :delivery_node_router, NodeRouter)

    outgoing = %{
      outgoing
      | metadata:
          Map.take(outgoing.metadata || %{}, [
            :user_message_id,
            :assistant_message_id,
            :persisted_assistant_message_id
          ])
    }

    event =
      Event.new(%{receipt: receipt, outgoing: outgoing}, :engine,
        opts: [action: :record_delivery_confirmation]
      )

    case router.dispatch(event) do
      %Event{response: {:ok, result}} ->
        {:ok, result}

      _ ->
        {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
    end
  rescue
    _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  catch
    _kind, _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  end

  def record({:error, _} = response, %Outgoing{} = outgoing, opts) do
    record(response, outgoing, nil, opts)
  end

  def record({:error, _, _} = response, %Outgoing{} = outgoing, opts) do
    record(response, outgoing, nil, opts)
  end

  def record(response, _outgoing, _opts), do: response

  @doc "Reports supplied safe evidence separately from the unchanged delivery result."
  def record({:error, _} = response, %Outgoing{} = outgoing, observation, opts) do
    report_observation(observation, outgoing, opts)
    response
  end

  def record({:error, _, _} = response, %Outgoing{} = outgoing, observation, opts) do
    report_observation(observation, outgoing, opts)
    response
  end

  def record(response, outgoing, _observation, opts), do: record(response, outgoing, opts)

  defp report_observation(observation, outgoing, opts) do
    metadata = outgoing.metadata || %{}

    answer_id =
      Map.get(metadata, :persisted_assistant_message_id, metadata[:assistant_message_id])

    if is_binary(answer_id) and is_binary(metadata[:user_message_id]) do
      observation =
        Map.merge(safe_observation(observation), %{
          assistant_message_id: answer_id,
          user_message_id: metadata[:user_message_id],
          channel_config_id: Map.get(outgoing.routing_context || %{}, :channel_config_id)
        })

      router = Keyword.get(opts, :delivery_node_router, NodeRouter)

      Event.new(observation, :engine,
        opts: [action: :record_delivery_observation, confidential: true]
      )
      |> router.dispatch()
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _ -> :ok
  end

  defp safe_observation(%{delivery_parts: evidence}), do: %{delivery_parts: evidence}

  defp safe_observation(%{outcome: outcome, reason: reason} = observation)
       when outcome in [:failed, :unconfirmed] and reason in @reasons and
              (outcome != :failed or
                 reason in [:rejected, :missing_configuration, :unsupported_provider]) do
    facts = Map.take(observation, [:outcome, :reason])

    case observation[:provider_code] do
      code when is_integer(code) and code in 0..999 -> Map.put(facts, :provider_code, code)
      _ -> facts
    end
  end

  defp safe_observation(_observation), do: %{outcome: :unconfirmed, reason: :unknown}
end
