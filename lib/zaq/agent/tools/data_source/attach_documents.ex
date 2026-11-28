defmodule Zaq.Agent.Tools.DataSource.AttachDocuments do
  @moduledoc """
  Authorizes document selection for one pending native request.

  Returns an instruction for StreamEvents, which owns request-local selection.
  Source metadata is refreshed through GetDocument; generic signed Records use
  Record authorization. Selection never acquires bytes or checks destination
  limits. Successful selection does not confirm upload or delivery.
  """

  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.{Authorization, Provenance}
  alias Zaq.Events.TrustedContext
  alias Zaq.Identity.ActorNormalizer

  use Zaq.Engine.Workflows.Action,
    name: "attach_documents",
    description: """
    Select complete document Records returned by document tools for this response.
    add keeps existing files and deduplicates; remove only deselects; replace sets
    the exact selection, including an empty list to clear it. Include every file
    requested, regardless of size; Channels applies destination limits later.
    A failed call leaves the earlier selection intact. You can correct the call
    and retry. Success means selected for delivery, never uploaded or delivered.
    """,
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["add", "remove", "replace"]),
        records: Zoi.list(Record.zoi_type(), max_length: 100)
      }),
    output_schema:
      Zoi.object(%{
        operation: Zoi.enum(["add", "remove", "replace"]),
        records: Zoi.list(Record.zoi_type(), max_length: 100)
      })

  @impl Jido.Action
  def run(%{operation: operation, records: records}, context) do
    with :ok <- active_request(context),
         :ok <- identified_actor(context),
         {:ok, records} <- authorize_records(records, context) do
      {:ok, %{operation: operation, records: records}}
    end
  end

  @doc "Applies a validated instruction in source order without I/O or persistent state."
  @spec reduce_selection([Record.t()], map()) :: {:ok, [Record.t()]}
  def reduce_selection(selected, %{operation: "add", records: records}),
    do: {:ok, Enum.uniq_by(selected ++ records, &selection_identity/1)}

  def reduce_selection(_selected, %{operation: "replace", records: records}),
    do: {:ok, Enum.uniq_by(records, &selection_identity/1)}

  def reduce_selection(selected, %{operation: "remove", records: records}) do
    removed = MapSet.new(records, &selection_identity/1)
    {:ok, Enum.reject(selected, &MapSet.member?(removed, selection_identity(&1)))}
  end

  defp active_request(%{request_id: id, state: %{requests: requests}})
       when is_binary(id) and id != "" and is_map(requests) do
    case Map.get(requests, id) do
      %{status: :pending} -> :ok
      _ -> {:error, :inactive_attachment_selection}
    end
  end

  defp active_request(_context), do: {:error, :inactive_attachment_selection}

  defp identified_actor(context) do
    trusted = TrustedContext.normalize(context)
    actor = Map.get(context, :actor)

    if is_map(actor) and (trusted.skip_permissions or identified?(actor)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp identified?(%Person{id: id}), do: is_integer(id) and id > 0
  defp identified?(actor), do: not is_nil(ActorNormalizer.person_id(actor))

  defp authorize_records(records, context) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, authorized} ->
      case authorize_record(record, context) do
        {:ok, current} -> {:cont, {:ok, [current | authorized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp authorize_record(%Record{kind: :file, id: id} = record, context)
       when is_binary(id) and id != "" do
    with {:ok, claims} <- Provenance.verify(record),
         true <- valid_identity?(claims),
         {:ok, current} <- current_record(record, claims, context) do
      {:ok, %{current | content: nil, raw: %{}}}
    else
      _ -> {:error, :unauthorized_document}
    end
  end

  defp authorize_record(_record, _context), do: {:error, :expected_document_records}

  defp current_record(record, %{"provider" => provider} = claims, context)
       when is_binary(provider) and provider != "" do
    params = %{provider: provider, document_id: claims["provider_record_id"]}

    params =
      Enum.reduce(["config_id", "scope_id"], params, fn key, params ->
        if is_nil(claims[key]),
          do: params,
          else: Map.put(params, String.to_existing_atom(key), to_string(claims[key]))
      end)

    with {:ok, %{record: %Record{kind: :file} = current}} <-
           ActionContract.execute(GetDocument, params, context, trace_payload: false),
         {:ok, current_claims} <- Provenance.verify(current),
         true <- selection_identity(record) == identity(current_claims) do
      {:ok, current}
    else
      _ -> {:error, :unauthorized_document}
    end
  end

  defp current_record(record, _claims, context) do
    if TrustedContext.normalize(context).skip_permissions or
         Authorization.can?(context.actor, record, :read),
       do: {:ok, record},
       else: {:error, :unauthorized_document}
  end

  defp selection_identity(record) do
    {:ok, claims} = Provenance.verify(record)
    identity(claims)
  end

  defp identity(claims),
    do:
      {claims["provider"], claims["config_id"], claims["scope_id"], claims["provider_record_id"]}

  defp valid_identity?(claims),
    do: is_binary(claims["provider_record_id"]) and claims["provider_record_id"] != ""
end
