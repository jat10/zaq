defmodule Zaq.Ingestion.PostProcessing.Worker do
  @moduledoc """
  Shared worker for durable processor reservations.

  Explicit processor/provider errors finish terminally without Oban retries.
  Infrastructure exceptions remain retryable; later attempts recover a running
  reservation. A duplicate first delivery cannot repeat completed or running work.
  """
  use Oban.Worker, queue: :post_processing, max_attempts: 3
  import Ecto.Query
  alias Zaq.Ingestion.PostProcessing
  alias Zaq.Ingestion.PostProcessing.Request
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(job), do: perform(job, [])

  def perform(%Oban.Job{args: %{"request_id" => id}} = job, opts) do
    with {:ok, request} <- claim(id, job.attempt),
         {:ok, module} <- PostProcessing.processor(request.processor, opts) do
      case module.perform(request, opts) do
        :ok -> PostProcessing.finish(id, "completed")
        {:skip, reason} -> PostProcessing.finish(id, "skipped", to_string(reason))
        {:error, reason} -> PostProcessing.finish(id, "failed", to_string(reason))
      end
    else
      {:skip, _} -> :ok
      {:error, :unknown_processor} -> PostProcessing.finish(id, "failed", "unknown_processor")
    end
  rescue
    error ->
      if job.attempt >= job.max_attempts,
        do: PostProcessing.finish(id, "failed", "infrastructure_failure")

      reraise error, __STACKTRACE__
  end

  defp claim(id, attempt) do
    Repo.transaction(fn ->
      case Repo.one(from r in Request, where: r.id == ^id, lock: "FOR UPDATE") do
        %Request{status: "pending"} = request -> run(request)
        %Request{status: "running"} = request when attempt > 1 -> request
        _ -> Repo.rollback(:already_finished)
      end
    end)
    |> case do
      {:error, :already_finished} -> {:skip, :already_finished}
      result -> result
    end
  end

  defp run(request), do: request |> Ecto.Changeset.change(status: "running") |> Repo.update!()
end
