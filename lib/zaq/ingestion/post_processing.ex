defmodule Zaq.Ingestion.PostProcessing do
  @moduledoc """
  Transactional dispatcher for registered Ingestion post-processors.

  The processor key is statically allowlisted; job arguments contain only the
  durable reservation ID. Eligibility, request payload and result policy belong
  to each processor. Scheduling does not invoke providers.
  """
  import Ecto.Query
  alias Zaq.Ingestion.DocumentGeneration
  alias Zaq.Ingestion.PostProcessing.{Request, Worker}
  alias Zaq.Repo

  @processors %{"labeling" => Zaq.Ingestion.PostProcessing.Processors.Labeling}

  @doc "Resolves only registered keys; implementations are a trusted runtime configuration seam."
  def processor(key, opts \\ []) do
    case Map.fetch(@processors, key) do
      {:ok, module} -> {:ok, Zaq.Config.get(:zaq, :labeling_processor, module, opts)}
      :error -> {:error, :unknown_processor}
    end
  end

  def schedule(resource, context, opts \\ []) do
    Repo.transaction(fn ->
      document = DocumentGeneration.lock!(resource.document_id)
      if document.generation != resource.generation, do: Repo.rollback(:stale_generation)

      Enum.flat_map(@processors, fn {key, _} ->
        {:ok, module} = processor(key, opts)
        reserve(module, key, resource, context)
      end)
    end)
  end

  defp reserve(module, key, resource, context) do
    if module.eligible?(resource, context) do
      module.reserve(resource, context)
      |> Enum.flat_map(&enqueue(&1, key, resource))
    else
      []
    end
  end

  defp enqueue(data, key, resource) do
    identity = [
      processor: key,
      resource_type: resource.type,
      resource_id: resource.id,
      generation: resource.generation,
      request_key: data.request_key
    ]

    case Repo.get_by(Request, identity) do
      nil ->
        request =
          struct!(Request, identity ++ [document_id: resource.document_id, payload: data.payload])
          |> Repo.insert!()

        {:ok, _job} = %{"request_id" => request.id} |> Worker.new() |> Oban.insert()
        [request]

      _ ->
        []
    end
  end

  @doc "Finishes only a live attempt, preserving invalidation by replacement or deletion."
  def finish(id, status, error \\ nil) do
    Repo.update_all(from(r in Request, where: r.id == ^id and r.status in ["pending", "running"]),
      set: [status: status, error: error, updated_at: DateTime.utc_now()]
    )

    :ok
  end
end
