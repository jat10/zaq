defmodule Zaq.Agent.Tools.DataSource.AttachDocuments do
  @moduledoc """
  Selects validated Records for the active request's final response.

  Selection does not deliver, materialize, or delete documents. Signed data-source
  Records reuse GetDocument for current authorized metadata; other signed Records
  reuse Record authorization. This Action returns a validated selection instruction;
  StreamEvents owns its request-local accumulation. The pure reducer below owns
  document identity and ordering. Standalone and workflow callers require the same
  trusted native request context and cannot deliver files by invoking this Action.
  """

  alias Jido.Action.Tool
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Channels.Events
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Authorization
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Events.TrustedContext
  alias Zaq.Identity.ActorNormalizer

  use Zaq.Engine.Workflows.Action,
    name: "attach_documents",
    description: """
    Select loaded document Records for this response. add deduplicates, remove
    deselects without deleting sources, replace sets the exact selection (empty
    clears it). Selection is not delivery; files are sent only after a successful
    final answer. Pass complete Records returned by document tools.
    Include every file the user requested, even when its size exceeds a transport
    limit. Do not omit files based on size or anticipated delivery failures;
    Channels applies the configured stop-or-continue policy.
    Tool success confirms selection only, not upload or delivery. Never claim
    files are attached, uploaded or sent based on this tool's result. Say they
    are selected for delivery. If any selection call failed in this request,
    explain that failure even after a successful retry: stop-on-failure can still
    prevent delivery of the entire selection.
    The errors list reports rejected files even when the call succeeds. Report
    these failures; do not retry with a subset to erase them.
    """,
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["add", "remove", "replace"]),
        records: Zoi.list(Record.zoi_type(), max_length: 100)
      }),
    output_schema:
      Zoi.object(%{
        operation: Zoi.enum(["add", "remove", "replace"]),
        records: Zoi.list(Record.zoi_type(), max_length: 100),
        errors:
          Zoi.list(
            Zoi.object(%{
              record_id: Zoi.string(),
              name: Zoi.string(),
              reason: Zoi.literal("file_too_large"),
              size: Zoi.integer(),
              limit: Zoi.integer()
            }),
            max_length: 100
          )
          |> Zoi.default([])
      })

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{operation: operation, records: records}, context) do
    with :ok <- active_request(context),
         {:ok, records} <- authorize(records, context),
         {:ok, records, errors} <- select_for_destination(operation, records, context) do
      {:ok, %{operation: operation, records: records, errors: errors}}
    end
  end

  defp select_for_destination(operation, records, context) do
    case validate_destination(operation, records, context) do
      :ok ->
        {:ok, records, []}

      {:error, {:file_too_large, %{filename: name, size: size, limit: limit}}} = error
      when is_binary(name) and is_integer(size) and is_integer(limit) and size > limit and
             limit > 0 ->
        {rejected, remaining} = Enum.split_with(records, &(&1.name == name and &1.size == size))

        retain_rejections(rejected, remaining, operation, context, error)

      {:error, _} = error ->
        error
    end
  end

  defp retain_rejections([], _remaining, _operation, _context, error), do: error

  defp retain_rejections(
         rejected,
         remaining,
         operation,
         context,
         {:error, {:file_too_large, %{size: size, limit: limit}}}
       ) do
    failures =
      Enum.map(
        rejected,
        &%{record_id: &1.id, name: &1.name, reason: "file_too_large", size: size, limit: limit}
      )

    with {:ok, selected, later_failures} <- select_for_destination(operation, remaining, context) do
      {:ok, selected, failures ++ later_failures}
    end
  end

  @doc "Applies one validated instruction to the current selection without side effects."
  @spec reduce_selection([Record.t()], %{operation: String.t(), records: [Record.t()]}) ::
          {:ok, [Record.t()]}
  def reduce_selection(selected, %{operation: "add", records: records}),
    do: {:ok, Enum.uniq_by(selected ++ records, &selection_identity/1)}

  def reduce_selection(_selected, %{operation: "replace", records: records}),
    do: {:ok, Enum.uniq_by(records, &selection_identity/1)}

  def reduce_selection(selected, %{operation: "remove", records: records}) do
    removed = MapSet.new(records, &selection_identity/1)
    {:ok, Enum.reject(selected, &MapSet.member?(removed, selection_identity(&1)))}
  end

  defp active_request(%{request_id: id, state: %{requests: requests}})
       when is_binary(id) and is_map(requests) do
    case Map.get(requests, id) do
      %{status: :pending} -> :ok
      _ -> {:error, :inactive_attachment_selection}
    end
  end

  defp active_request(_context), do: {:error, :inactive_attachment_selection}

  defp validate_destination("remove", _records, _context), do: :ok
  defp validate_destination(_operation, [], _context), do: :ok

  defp validate_destination(_operation, _records, %{incoming: %Incoming{provider: provider}})
       when provider in [nil, ""],
       do: :ok

  defp validate_destination(_operation, records, %{incoming: %Incoming{} = incoming} = context) do
    outgoing = %Outgoing{
      body: "",
      provider: incoming.provider,
      channel_id: incoming.channel_id,
      routing_context: incoming.routing_context,
      delivery: %Outgoing.Delivery{attachments: Enum.map(records, &%{&1 | content: nil})}
    }

    opts = TrustedContext.event_builder_opts(context)

    case Events.build_and_dispatch_validate_files_event(outgoing, opts) do
      %Event{response: :ok} -> :ok
      %Event{response: {:error, _} = error} -> error
      {:error, _} = error -> error
      _ -> {:error, :file_validation_unavailable}
    end
  end

  # Workflow selections may not have a delivery destination until a later step.
  defp validate_destination(_operation, _records, _context), do: :ok

  defp selection_identity(%Record{} = record) do
    {:ok, claims} = Provenance.verify(record)
    {claims["provider"], claims["config_id"], claims["provider_record_id"]}
  end

  defp authorize(records, context) do
    actor = Map.get(context, :actor)
    bypass? = Map.get(context, :skip_permissions) == true

    cond do
      not bypass? and not identified?(actor) -> {:error, :unauthorized}
      Enum.any?(records, &(&1.kind != :file)) -> {:error, :expected_document_records}
      bypass? -> {:ok, records}
      true -> authorize_records(records, context)
    end
  end

  defp authorize_records(records, context) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, validated} ->
      case authorized_record(record, context) do
        {:ok, record} -> {:cont, {:ok, [record | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp authorized_record(record, context) do
    case Provenance.verify(record) do
      {:ok, %{"provider" => provider} = claims} when is_binary(provider) ->
        params = %{provider: provider, document_id: claims["provider_record_id"]}

        params =
          if claims["config_id"],
            do: Map.put(params, :config_id, to_string(claims["config_id"])),
            else: params

        case Jido.Exec.run(GetDocument, params, context) do
          {:ok, %{record: %Record{kind: :file} = current}} -> {:ok, current}
          _ -> {:error, :unauthorized}
        end

      {:ok, _claims} ->
        if Authorization.can?(Map.get(context, :actor), record, :read),
          do: {:ok, record},
          else: {:error, :unauthorized}

      {:error, _} ->
        {:error, :invalid_record}
    end
  end

  defp identified?(%Person{id: id}), do: is_integer(id) and id > 0
  defp identified?(actor), do: not is_nil(ActorNormalizer.person_id(actor))
end
