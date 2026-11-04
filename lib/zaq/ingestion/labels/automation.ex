defmodule Zaq.Ingestion.Labels.Automation do
  @moduledoc """
  Reserves and conditionally applies automatic category decisions.

  Each reservation captures the definition, assignment and resource generation,
  and the shared threshold. Manual provenance always wins, including exclusions
  and value-only edits. Failed replacements leave the last effective result intact.
  Provider inference uses the generic confidential Agent classify operation outside locks.
  """
  import Ecto.Query
  alias Zaq.Ingestion.{Chunk, Document, DocumentGeneration, IngestJob}
  alias Zaq.Ingestion.Labels.{ChunkAssignment, DocumentAssignment, Label, Target}
  alias Zaq.Ingestion.PostProcessing.Request
  alias Zaq.Repo

  def eligible?(_resource, context) do
    config = Zaq.System.get_rag_model_config(:decision)

    context[:classification_state] == "enabled" and not is_nil(config.credential_id) and
      not is_nil(config.model)
  end

  def reserve(resource, context) do
    threshold = Zaq.System.get_rag_model_config(:decision).classification_threshold

    assignments =
      Repo.all(
        from a in schema(resource.type), where: field(a, ^key(resource.type)) == ^resource.id
      )
      |> Map.new(&{&1.label_id, &1})

    manual_ids = for {id, %{origin: :manual}} <- assignments, do: id

    Repo.all(
      from l in Label,
        join: t in Target,
        on: t.label_id == l.id,
        where: t.resource_type == ^resource.type and t.automatic and l.id not in ^manual_ids,
        order_by: l.id
    )
    |> Enum.map(fn label ->
      version = if assignments[label.id], do: assignments[label.id].lock_version, else: 0

      %{
        request_key: "#{label.id}:#{label.lock_version}:#{context[:request_key] || "ingestion"}",
        payload: %{
          "label_id" => label.id,
          "definition_version" => label.lock_version,
          "assignment_version" => version,
          "threshold" => threshold,
          "job_id" => context[:job_id],
          "actor" => context[:actor],
          "authorize_actor" => context[:authorize_actor] == true
        }
      }
    end)
  end

  def perform(request, opts \\ []) do
    with {:ok, %{text: text, label: label}} <- prepare(request),
         {:ok, probability} <- classify(request, label, text, opts) do
      apply_result(request, probability)
    else
      {:error, reason} when reason in [:obsolete, :manual_override, :run_skipped] ->
        {:skip, reason}

      {:error, _} ->
        {:error, :classification_failed}
    end
  end

  defp prepare(request) do
    Repo.transaction(fn ->
      {document, label, _assignment} = validate!(request)

      text =
        if request.resource_type == "document",
          do: document.content,
          else: Repo.get!(Chunk, request.resource_id).content

      %{text: text, label: label}
    end)
  end

  defp classify(request, label, text, opts) do
    router = Zaq.Config.get(:zaq, :node_router, Zaq.NodeRouter, opts)

    event =
      Zaq.Event.new(
        %{
          text: text,
          categories: [
            %{id: to_string(label.id), name: label.name, description: label.description}
          ]
        },
        :agent,
        opts: [action: :classify, confidential: true],
        actor: %{kind: :system, subject: "post-processing/#{request.id}"}
      )

    event = %{event | opts: Keyword.merge(event.opts, Keyword.take(opts, [:config]))}

    case router.dispatch(event).response do
      {:ok, %{probabilities: probabilities}} ->
        case probabilities[to_string(label.id)] do
          p when is_number(p) and p >= 0 and p <= 1 -> {:ok, p}
          _ -> {:error, :invalid_result}
        end

      _ ->
        {:error, :classification_failed}
    end
  end

  @doc "Applies a completed probability only if every captured write guard still matches."
  def apply_result(request, probability)
      when is_number(probability) and probability >= 0 and probability <= 1 do
    Repo.transaction(fn ->
      {_document, label, assignment} = validate!(request)

      assignment =
        assignment ||
          struct(schema(request.resource_type), [
            {key(request.resource_type), request.resource_id},
            {:label_id, label.id}
          ])

      changes = %{
        origin: :automatic,
        selected: probability * 100 >= request.payload["threshold"],
        probability: probability,
        definition_version: label.lock_version,
        generation: request.generation,
        request_id: request.id,
        value: nil,
        lock_version: assignment.lock_version + if(assignment.id, do: 1, else: 0)
      }

      assignment |> Ecto.Changeset.change(changes) |> Repo.insert_or_update!()
    end)
    |> case do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Zaq.PubSub,
          "ingestion:labels",
          {:automatic_labels_updated, %{type: request.resource_type, id: request.resource_id}}
        )

        :ok

      {:error, reason} ->
        {:skip, reason}
    end
  end

  def apply_result(_, _), do: {:error, :invalid_probability}

  @doc "Latest attempt per label for a resource already authorized by the caller."
  def attempts(type, id) do
    Repo.all(
      from r in Request,
        join: d in Document,
        on: d.id == r.document_id and d.generation == r.generation,
        where: r.resource_type == ^type and r.resource_id == ^id,
        distinct: fragment("?->>'label_id'", r.payload),
        order_by: [asc: fragment("?->>'label_id'", r.payload), desc: r.inserted_at]
    )
    |> Map.new(&{&1.payload["label_id"], &1})
  end

  @doc "Result freshness and attempt state never alter the effective manual/automatic selection."
  def metadata(assignment, label, attempt) do
    automatic? = assignment != nil and assignment.origin == :automatic
    manual? = assignment != nil and assignment.origin == :manual

    current_attempt? =
      attempt != nil and attempt.payload["definition_version"] == label.lock_version

    %{
      origin: if(assignment, do: assignment.origin, else: nil),
      probability: if(automatic?, do: assignment.probability, else: nil),
      stale: automatic? and assignment.definition_version != label.lock_version,
      processing_status: if(current_attempt? and not manual?, do: attempt.status, else: nil)
    }
  end

  defp validate!(request) do
    document = DocumentGeneration.lock!(request.document_id)
    validate_actor!(request, document)
    if document.generation != request.generation, do: Repo.rollback(:obsolete)

    label =
      Repo.one(from l in Label, where: l.id == ^request.payload["label_id"], lock: "FOR UPDATE")

    if is_nil(label) or label.lock_version != request.payload["definition_version"],
      do: Repo.rollback(:obsolete)

    unless Repo.exists?(
             from t in Target,
               where:
                 t.label_id == ^label.id and t.resource_type == ^request.resource_type and
                   t.automatic
           ),
           do: Repo.rollback(:obsolete)

    validate_run!(request)
    validate_resource!(request)

    assignment =
      Repo.one(
        from a in schema(request.resource_type),
          where:
            field(a, ^key(request.resource_type)) == ^request.resource_id and
              a.label_id == ^label.id,
          lock: "FOR UPDATE"
      )

    validate_assignment!(request, assignment)

    {document, label, assignment}
  end

  defp validate_assignment!(request, assignment) do
    if assignment && assignment.origin == :manual, do: Repo.rollback(:manual_override)
    version = if assignment, do: assignment.lock_version, else: 0
    if version != request.payload["assignment_version"], do: Repo.rollback(:obsolete)
    current = Repo.get(Request, request.id)

    if is_nil(current) or current.status not in ["pending", "running"],
      do: Repo.rollback(:obsolete)
  end

  defp validate_run!(%{payload: %{"job_id" => id}}) when is_binary(id) do
    case Repo.get(IngestJob, id) do
      %{classification_state: "enabled"} -> :ok
      _ -> Repo.rollback(:run_skipped)
    end
  end

  defp validate_run!(_), do: :ok

  defp validate_actor!(%{payload: %{"authorize_actor" => true, "actor" => actor}}, document) do
    actor = %{
      user_id: actor["user_id"] || actor[:user_id],
      person_id: actor["person_id"] || actor[:person_id]
    }

    if Zaq.Ingestion.Labels.Access.resource(actor, document, :read) != :ok or
         Zaq.Ingestion.Labels.Access.resource(actor, document, :update) != :ok,
       do: Repo.rollback(:obsolete)
  end

  defp validate_actor!(_, _), do: :ok

  defp validate_resource!(%{resource_type: "chunk"} = request) do
    unless Chunk.table_exists?() and
             Repo.exists?(
               from c in Chunk,
                 where: c.id == ^request.resource_id and c.document_id == ^request.document_id
             ),
           do: Repo.rollback(:obsolete)
  end

  defp validate_resource!(_), do: :ok

  defp schema("document"), do: DocumentAssignment
  defp schema("chunk"), do: ChunkAssignment
  defp key("document"), do: :document_id
  defp key("chunk"), do: :chunk_id
end
