defmodule Zaq.Agent.DecisionReadinessTest do
  use Zaq.DataCase, async: true
  alias Zaq.Agent.Actions.CheckDecisionModel
  alias Zaq.TestSupport.OpenAIStub
  @actor %{kind: :system, subject: "readiness"}

  test "absent configuration is distinct from a failed configured model" do
    assert {:ok, %{status: "unconfigured", configured: false}} =
             Jido.Exec.run(CheckDecisionModel, %{}, %{actor: @actor})

    assert {:error, :missing_execution_actor} = CheckDecisionModel.run(%{}, %{})
  end

  test "fixed minimal probe exercises actual authentication and boolean response validation" do
    {_pid, endpoint} =
      OpenAIStub.start!(
        fn _conn, body ->
          request = Jason.decode!(body)
          assert Jason.decode!(request["input"])["text"] == "Readiness check."

          {200,
           %{
             model: "gpt-6-luna",
             usage: %{},
             answers: [%{name: "ready", type: "predicate", probability: 0.99}]
           }}
        end,
        self()
      )

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "probe-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    assert {:ok, %{status: "ready", configured: true}} =
             Jido.Exec.run(CheckDecisionModel, %{}, %{actor: @actor})

    assert_receive {:openai_request, "POST", "/v1/decisions", _, _}
  end
end
