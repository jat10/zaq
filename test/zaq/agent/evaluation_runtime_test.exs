defmodule Zaq.Agent.EvaluationRuntimeTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System.RAGModelConfig

  test "missing Decision selection has no generation fallback" do
    assert {:error, :model_not_configured} = ProviderSpec.evaluation_runtime(%RAGModelConfig{})
  end

  test "Decision runtime uses canonical credentials without sampling options" do
    credential = ai_credential_fixture(%{provider: "openai", api_key: "evaluation-secret"})
    config = %RAGModelConfig{credential_id: credential.id, model: "gpt-6-luna"}

    assert {:ok, %{provider: :openai, id: "gpt-6-luna"}, opts} =
             ProviderSpec.evaluation_runtime(config)

    assert opts[:api_key] == "evaluation-secret"
    assert opts[:total_timeout] == 15_000
    assert opts[:max_retries] == 0
    refute Keyword.has_key?(opts, :temperature)
    refute Keyword.has_key?(opts, :top_p)
  end

  test "a generation model cannot serve as a Decision model" do
    credential = ai_credential_fixture(%{provider: "openai", api_key: "evaluation-secret"})
    config = %RAGModelConfig{credential_id: credential.id, model: "gpt-4.1-mini"}
    assert {:error, :evaluation_not_supported} = ProviderSpec.evaluation_runtime(config)
  end

  test "installed evaluator sends boolean questions and normalizes probabilities" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/decisions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"input" => "Please refund my order", "questions" => questions} =
               Jason.decode!(body)

      assert length(questions) == 1

      Req.Test.json(conn, %{
        model: "gpt-6-luna",
        answers: [%{name: "billing", type: "predicate", probability: 0.94}],
        usage: %{}
      })
    end)

    credential = ai_credential_fixture(%{provider: "openai", api_key: "evaluation-secret"})

    assert {:ok, spec, opts} =
             ProviderSpec.evaluation_runtime(%RAGModelConfig{
               credential_id: credential.id,
               model: "gpt-6-luna"
             })

    assert {:ok, %{object: %{"billing" => %{"type" => "boolean", "probability" => 0.94}}}} =
             ReqLLM.evaluate(
               spec,
               "Please refund my order",
               %{"billing" => %{type: :boolean, instructions: "Is this a billing request?"}},
               Keyword.put(opts, :req_http_options, plug: {Req.Test, __MODULE__})
             )
  end
end
