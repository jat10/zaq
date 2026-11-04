defmodule Zaq.Ingestion.Labels.Reclassification do
  @moduledoc """
  Confirmed reclassification of authorized current chunks carrying an edited label.

  Preview tokens cover definition and exact affected chunk/assignment generations.
  Confirmation reruns authorization and checks the same snapshot under ordered
  document locks before reserving all eligible automatic labels on those chunks.
  New definitions and unassigned/negative chunks never trigger backfill.
  """
  import Ecto.Query
  alias Zaq.Ingestion.{Chunk, ClassificationRun, DocumentGeneration, PostProcessing}
  alias Zaq.Ingestion.Labels.{Access, ChunkAssignment, Label}
  alias Zaq.Repo

  def preview(id, version, actor) do
    with {:ok, user} <- Access.user(actor),
         :ok <- Access.manager(actor),
         %Label{lock_version: ^version} <- Repo.get(Label, id) do
      rows = affected(id, actor, user)
      {:ok, snapshot(id, version, rows)}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale}
    end
  end

  def confirm(id, version, token, actor, opts \\ []) do
    with {:ok, user} <- Access.user(actor),
         :ok <- Access.manager(actor),
         {:ok, %ClassificationRun{state: "enabled"}} <- ClassificationRun.prepare(%{}, opts) do
      Repo.transaction(fn -> reserve_confirmed(id, version, token, actor, user, opts) end)
    else
      {:ok, _} -> {:error, :automation_unavailable}
      error -> error
    end
  end

  defp reserve_confirmed(id, version, token, actor, user, opts) do
    rows = affected(id, actor, user)

    rows
    |> Enum.map(& &1.document_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&DocumentGeneration.lock!/1)

    label = Repo.one(from l in Label, where: l.id == ^id, lock: "FOR UPDATE")
    if is_nil(label) or label.lock_version != version, do: Repo.rollback(:stale)
    rows = affected(id, actor, user)

    if snapshot(id, version, rows).confirmation_token != token,
      do: Repo.rollback(:affected_chunks_changed)

    requests =
      Enum.flat_map(rows, fn row ->
        resource = %{
          type: "chunk",
          id: row.id,
          document_id: row.document_id,
          generation: row.generation
        }

        context = %{
          classification_state: "enabled",
          actor: actor,
          authorize_actor: true,
          request_key: "reclassify:#{id}:#{version}"
        }

        case PostProcessing.schedule(resource, context, opts) do
          {:ok, requests} -> requests
          {:error, error} -> Repo.rollback(error)
        end
      end)

    %{chunks: length(rows), requests: length(requests)}
  end

  defp affected(id, actor, user) do
    if Chunk.table_exists?() do
      readable = Access.document_ids_query(actor, user, :read)
      writable = Access.document_ids_query(actor, user, :update)

      Repo.all(
        from a in ChunkAssignment,
          join: c in Chunk,
          on: c.id == a.chunk_id,
          join: d in assoc(c, :document),
          where:
            a.label_id == ^id and a.selected and d.id in subquery(readable) and
              d.id in subquery(writable),
          order_by: c.id,
          select: %{
            id: c.id,
            document_id: d.id,
            generation: d.generation,
            assignment_version: a.lock_version
          }
      )
    else
      []
    end
  end

  defp snapshot(id, version, rows) do
    token =
      :crypto.hash(:sha256, :erlang.term_to_binary({id, version, rows}))
      |> Base.url_encode64(padding: false)

    %{
      label_id: id,
      expected_version: version,
      affected_chunks: length(rows),
      confirmation_token: token
    }
  end
end
