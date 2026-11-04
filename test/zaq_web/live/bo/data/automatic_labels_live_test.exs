defmodule ZaqWeb.Live.BO.Data.AutomaticLabelsLiveTest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Chunk, Document, Labels}
  alias Zaq.Ingestion.PostProcessing.Request
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

  test "configured controls save and Not now retains current carriers without scheduling", %{
    conn: conn
  } do
    {_pid, endpoint} =
      OpenAIStub.start!(
        fn _conn, _body ->
          {200,
           %{
             model: "gpt-6-luna",
             usage: %{},
             answers: [%{name: "ready", type: "predicate", probability: 1.0}]
           }}
        end,
        self()
      )

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "ui-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}

    {:ok, label} =
      Labels.save_definition(
        %{name: "Original", targets: ["chunk"], automatic_chunk: true},
        actor
      )

    {:ok, doc} = Document.create(%{source: "ui-carrier"})
    chunk = Repo.insert!(%Chunk{document_id: doc.id, chunk_index: 1, content: "text"})

    {:ok, _} =
      Labels.edit_resource(
        %{type: "chunk", id: chunk.id},
        [%{label_id: label.id, expected_version: 0, operation: "add"}],
        actor
      )

    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/bo/labels")
    view |> element("#labels-#{label.id}") |> render_click()
    assert has_element?(view, "#label-automatic-chunk[checked]")

    view
    |> form("#label-definition-form",
      label: %{
        name: "Updated",
        description: "changed",
        chunk: "true",
        document: "false",
        automatic_chunk: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#label-reclassification-modal", "1 chunks")
    assert Repo.aggregate(Request, :count) == 0
    refute_received {:openai_request, _, _, _, _}
    view |> element("button[phx-click=skip_reclassification]", "Not now") |> render_click()
    refute has_element?(view, "#label-reclassification-modal")
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.get!(Labels.Label, label.id).name == "Updated"

    assert {:ok, %{resources: 1}} =
             Labels.value_summaries([label.id], actor)
             |> then(fn {:ok, values} -> {:ok, values[label.id]} end)

    {:ok, _} =
      Labels.save_definition(
        %{name: "Another automatic label", targets: ["chunk"], automatic_chunk: true},
        actor
      )

    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{opts: opts} = event ->
      assert opts[:action] == :check_decision_model
      Zaq.NodeRouter.dispatch(event)
    end)

    view |> element("#labels-#{label.id}") |> render_click()

    view
    |> form("#label-definition-form",
      label: %{
        name: "Updated again",
        description: "changed again",
        chunk: "true",
        document: "false",
        automatic_chunk: "true"
      }
    )
    |> render_submit()

    view |> element("#confirm-label-reclassification") |> render_click()
    refute has_element?(view, "#label-reclassification-modal")
    assert Repo.aggregate(Request, :count) == 1
  end
end
