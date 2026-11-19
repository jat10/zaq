defmodule Zaq.Channels.Delivery.Confirmation do
  @moduledoc """
  Reports normalized transport confirmations and unsuccessful outcomes to Engine.

  Transport success is preserved even if the downstream consumer is unavailable;
  reporting a receipt must never cause the accepted message to be resent.
  Bridges and Channels preflight operations supply bounded unsuccessful evidence;
  this reporter never interprets provider errors or selects a transport policy.
  The confirmation copy removes the private delivery plan and clears attachment
  content while preserving Records and their materialization handles. Metadata
  retains only canonical IDs.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  @reasons [:rejected, :missing_configuration, :unsupported_provider, :timeout, :unknown]

  @doc "Forwards a confirmed receipt and outgoing copy with content-free attachment Records to Engine."
  def record({:ok, %{messages: messages} = report}, outgoing, opts) when is_list(messages) do
    receipts =
      Enum.map(messages, fn receipt ->
        attachments =
          if Map.has_key?(receipt, :delivered_attachment_indices),
            do: outgoing.delivery.attachments,
            else: []

        part = %{
          outgoing
          | body: confirmation_body(receipt, outgoing),
            thread_id: receipt[:thread_id],
            delivery: %{outgoing.delivery | attachments: attachments}
        }

        {:ok, recorded} = record({:ok, receipt}, part, opts)
        recorded
      end)

    {:ok, report |> Map.delete(:delivered_attachment_indices) |> Map.put(:messages, receipts)}
  end

  def record({:ok, %{confirmation: :confirmed} = receipt}, outgoing, opts) do
    router = Keyword.get(opts, :delivery_node_router, NodeRouter)
    attachments = confirmed_attachment_records(outgoing.delivery.attachments, receipt)

    receipt =
      receipt
      |> put_confirmed_attachment_metadata(attachments)
      |> Map.delete(:delivered_attachment_indices)

    outgoing = %{
      outgoing
      | metadata:
          Map.take(outgoing.metadata || %{}, [
            :user_message_id,
            :assistant_message_id,
            :persisted_assistant_message_id
          ]),
        delivery: %{
          outgoing.delivery
          | attachments: Enum.map(attachments, &%{&1 | content: nil}),
            plan: nil
        }
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
    :exit, _ ->
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

  defp confirmation_body(%{delivery_part_index: index} = receipt, outgoing)
       when is_integer(index),
       do: Map.get(receipt, :body, outgoing.body)

  defp confirmation_body(_receipt, outgoing), do: outgoing.body

  defp put_confirmed_attachment_metadata(
         %{delivered_attachment_indices: _} = receipt,
         attachments
       ) do
    metadata =
      Enum.map(attachments, fn record ->
        record |> Record.attachment_metadata() |> Map.drop(["id", "attributes"])
      end)

    Map.put_new(receipt, :attachments, metadata)
  end

  defp put_confirmed_attachment_metadata(receipt, _attachments), do: receipt

  defp confirmed_attachment_records(attachments, %{delivered_attachment_indices: indices})
       when is_list(indices) do
    attachments
    |> Enum.with_index()
    |> Enum.filter(fn {_record, index} -> index in indices end)
    |> Enum.map(&elem(&1, 0))
  end

  defp confirmed_attachment_records(_attachments, %{delivered_attachment_indices: _}), do: []

  defp confirmed_attachment_records(attachments, _receipt), do: attachments
end
