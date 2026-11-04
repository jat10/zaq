defmodule Zaq.Ingestion.ClassificationRun do
  @moduledoc """
  Immutable pre-ingestion classification choice shared by every child of a run.

  Only this server-created struct bypasses a repeated preflight during folder
  expansion. Persisted job state defaults to skipped for legacy queued work.
  Model recovery never changes that saved decision.
  """
  import Ecto.Query
  alias Zaq.Ingestion.Labels.Target
  alias Zaq.Repo
  require Logger

  defstruct state: "skipped", error: nil

  def prepare(params, opts \\ []) do
    case params[:classification_decision] do
      %__MODULE__{} = decision -> {:ok, decision}
      _ -> check(params, opts)
    end
  end

  defp check(params, opts) do
    config = Zaq.System.get_rag_model_config(:decision)

    cond do
      params[:classification_choice] == "proceed_without" ->
        {:ok, %__MODULE__{error: "skipped_by_user"}}

      is_nil(config.credential_id) or is_nil(config.model) ->
        {:ok, %__MODULE__{}}

      not Repo.exists?(from t in Target, where: t.automatic) ->
        {:ok, %__MODULE__{}}

      true ->
        probe(params, opts)
    end
  end

  defp probe(params, opts) do
    router = Zaq.Config.get(:zaq, :node_router, Zaq.NodeRouter, opts)

    event =
      Zaq.Event.new(%{}, :agent,
        opts:
          [action: :check_decision_model, confidential: true] ++ Keyword.take(opts, [:config]),
        actor: %{kind: :system, subject: "ingestion-preflight"}
      )

    case router.dispatch(event).response do
      {:ok, %{status: "ready"}} -> {:ok, %__MODULE__{state: "enabled"}}
      {:ok, %{status: "unconfigured"}} -> {:ok, %__MODULE__{}}
      _ -> failed(params)
    end
  rescue
    _ -> failed(params)
  end

  defp failed(%{interactive: true}),
    do: {:error, {:classification_confirmation_required, :decision_unavailable}}

  defp failed(_) do
    Logger.warning("Decision model check failed; ingestion will proceed without classification")
    {:ok, %__MODULE__{error: "decision_unavailable"}}
  end

  def context(job) do
    %{
      classification_state: job.classification_state,
      job_id: job.id,
      actor: get_in(job.source_record || %{}, ["materialization_context", "actor"])
    }
  end
end
