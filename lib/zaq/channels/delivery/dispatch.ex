defmodule Zaq.Channels.Delivery.Dispatch do
  @moduledoc "Wires the existing outgoing API to one selected attachment execution and its reports."

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.Delivery.{Attachments, Error, Executor, Result}
  alias Zaq.Channels.{DeliveryConfirmation, TransportRequirements}
  alias Zaq.ConnectorConfig.FileSettings
  alias Zaq.Engine.Messages.ConversationIdentity
  alias Zaq.Events.TrustedContext

  @doc "Resolves requirements once, executes once, and keeps completion/reporting failures separate."
  def run(canonical, formatted, bridge, connection, event) do
    snapshot = Bridge.capability_snapshot_for_connection(bridge, connection)

    requirements =
      case snapshot do
        {:ok, snapshot} -> TransportRequirements.resolve(snapshot, connection)
        _ -> {:error, :capabilities_unavailable}
      end

    context =
      event
      |> TrustedContext.from_event()
      |> Map.from_struct()
      |> Map.merge(Map.new(Keyword.take(event.opts, [:config, :node_router])))

    opts = event.opts |> Keyword.put(:context, context) |> text_options(snapshot, connection)

    response =
      case execute(formatted, requirements, bridge, connection, opts) do
        {:error, %Error{} = error} -> preflight_failure(formatted, error, opts)
        response -> response
      end

    DeliveryConfirmation.record_attempt(response, canonical, event.opts)
    complete(bridge, canonical, response)
    public_response(response)
  end

  defp execute(outgoing, {:ok, requirements}, bridge, connection, opts) do
    metadata = outgoing.metadata || %{}

    existing =
      ConversationIdentity.normalize(
        Map.get(metadata, :message_id) || Map.get(metadata, "message_id")
      )

    case Attachments.build_plan(outgoing, requirements, existing) do
      {:ok, plan} ->
        Executor.execute(outgoing, plan, bridge, connection, opts)

      {:error, cause} ->
        {:error,
         %Error{stage: :configuration, outcome: :failed, reason: :invalid_plan, cause: cause}}
    end
  end

  defp execute(outgoing, {:error, _} = failure, bridge, connection, opts),
    do: Executor.execute(outgoing, failure, bridge, connection, opts)

  defp text_options(opts, {:ok, snapshot}, connection) do
    if FileSettings.supported?(snapshot, :text) do
      case FileSettings.encoded_message_limit(FileSettings.from_connection(connection), snapshot) do
        {:ok, limit} ->
          opts |> Keyword.put(:max_text_request_bytes, limit) |> text_edit_options(snapshot)

        _ ->
          Keyword.delete(opts, :max_text_request_bytes)
      end
    else
      Keyword.delete(opts, :max_text_request_bytes)
    end
  end

  defp text_options(opts, _, _), do: Keyword.delete(opts, :max_text_request_bytes)

  defp text_edit_options(opts, snapshot),
    do: Keyword.put(opts, :text_edits?, FileSettings.supported?(snapshot, :edit_messages))

  defp preflight_failure(outgoing, error, opts) do
    refs =
      if is_list(outgoing.attachments),
        do: outgoing.attachments |> Enum.with_index() |> Enum.map(&elem(&1, 1)),
        else: []

    result = %Result{
      attempt_id: Keyword.get_lazy(opts, :attempt_id, &Ecto.UUID.generate/0),
      steps: [],
      failures: [%{group_id: nil, attachment_refs: refs, error: error}]
    }

    {:error, error, result}
  end

  defp complete(bridge, outgoing, {:ok, result}) do
    if function_exported?(bridge, :complete_delivery, 2),
      do: bridge.complete_delivery(outgoing, result)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp complete(_, _, _), do: :ok

  defp public_response({:ok, result}) do
    [receipt | _] = Result.confirmed_receipts(result)
    {:ok, Map.delete(receipt, :attachment_refs)}
  end

  defp public_response({:error, error, _}), do: public_response({:error, error})

  defp public_response({:error, %Error{} = error}) do
    {:ok, facts} = Error.safe_facts(error)
    {:error, facts}
  end
end
