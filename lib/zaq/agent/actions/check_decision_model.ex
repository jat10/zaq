defmodule Zaq.Agent.Actions.CheckDecisionModel do
  @moduledoc "Bounded Decision readiness probe reusing the validated generic classification operation."
  use Jido.Action,
    name: "check_decision_model",
    description: "Check the configured Decision model with a fixed minimal classification probe",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{status: Zoi.string(), configured: Zoi.boolean()})

  alias Zaq.Agent.Tools.General.Classify
  alias Zaq.Identity.ExecutionActor

  @impl Jido.Action
  def run(_params, context) do
    with {:ok, _} <- ExecutionActor.validate(context[:actor]) do
      config = Zaq.System.get_rag_model_config(:decision)

      if is_nil(config.credential_id) or is_nil(config.model) do
        {:ok, %{status: "unconfigured", configured: false}}
      else
        probe(context)
      end
    end
  end

  defp probe(context) do
    params = %{
      text: "Readiness check.",
      categories: [%{id: "ready", name: "Readiness", description: "This is a readiness check."}]
    }

    status =
      case Jido.Exec.run(Classify, params, context) do
        {:ok, %{probabilities: %{"ready" => p}}} when is_number(p) -> "ready"
        _ -> "failed"
      end

    {:ok, %{status: status, configured: true}}
  end
end
