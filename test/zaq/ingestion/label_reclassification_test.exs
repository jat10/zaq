defmodule Zaq.Ingestion.LabelReclassificationTest do
  use Zaq.DataCase, async: true
  import Ecto.Query
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Chunk, Document, Labels, PostProcessing}
  alias Zaq.Ingestion.Labels.{Automation, Reclassification}
  alias Zaq.Ingestion.PostProcessing.Request
  alias Zaq.TestSupport.OpenAIStub

  defmodule Config do
    def get(:zaq, :node_router, _), do: Zaq.NodeRouter
    def get(_, _, default), do: default
  end

  setup do
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
        api_key: "reclass-key"
      })

    {:ok, _} =
      Zaq.System.save_rag_model_config(:decision, %{
        credential_id: credential.id,
        model: "gpt-6-luna"
      })

    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}

    {:ok, first} =
      Labels.save_definition(%{name: "First", targets: ["chunk"], automatic_chunk: true}, actor)

    {:ok, second} =
      Labels.save_definition(%{name: "Second", targets: ["chunk"], automatic_chunk: true}, actor)

    {:ok, doc} = Document.create(%{source: Ecto.UUID.generate(), content: "text"})

    chunks =
      for index <- 1..4,
          do:
            Repo.insert!(%Chunk{
              document_id: doc.id,
              chunk_index: index,
              content: "text #{index}"
            })

    for chunk <- Enum.take(chunks, 2) do
      resource = %{type: "chunk", id: chunk.id, document_id: doc.id, generation: doc.generation}
      {:ok, requests} = PostProcessing.schedule(resource, %{classification_state: "enabled"})

      for request <- requests,
          do:
            Automation.apply_result(
              request,
              if(chunk.chunk_index == 1 and request.payload["label_id"] == first.id,
                do: 0.9,
                else: 0.1
              )
            )
    end

    manual = List.last(chunks)

    {:ok, _} =
      Labels.edit_resource(
        %{type: "chunk", id: manual.id},
        [%{label_id: first.id, operation: "add", expected_version: 0}],
        actor
      )

    {:ok, first} =
      Labels.save_definition(
        %{
          id: first.id,
          expected_version: first.lock_version,
          name: "Edited first",
          targets: ["chunk"]
        },
        actor
      )

    %{actor: actor, first: first, second: second, chunks: chunks}
  end

  test "confirmation schedules all eligible labels only on current carriers and is idempotent",
       ctx do
    assert {:ok, %{affected_chunks: 2} = preview} =
             Reclassification.preview(ctx.first.id, ctx.first.lock_version, ctx.actor)

    assert {:ok, %{chunks: 2, requests: 3}} =
             Reclassification.confirm(
               ctx.first.id,
               ctx.first.lock_version,
               preview.confirmation_token,
               ctx.actor,
               config: Config
             )

    assert {:ok, %{chunks: 2, requests: 0}} =
             Reclassification.confirm(
               ctx.first.id,
               ctx.first.lock_version,
               preview.confirmation_token,
               ctx.actor,
               config: Config
             )

    requests = Repo.all(from r in Request, where: like(r.request_key, "%reclassify:%"))

    assert Enum.sort(Enum.uniq(Enum.map(requests, & &1.resource_id))) == [
             hd(ctx.chunks).id,
             List.last(ctx.chunks).id
           ]

    assert Enum.sort(Enum.uniq(Enum.map(requests, & &1.payload["label_id"]))) ==
             Enum.sort([ctx.first.id, ctx.second.id])
  end

  test "nil identity and definition or affected-scope drift cannot authorize work", ctx do
    assert {:error, :unauthorized} =
             Reclassification.preview(ctx.first.id, ctx.first.lock_version, nil)

    assert {:error, :stale} =
             Reclassification.preview(ctx.first.id, ctx.first.lock_version - 1, ctx.actor)

    {:ok, preview} = Reclassification.preview(ctx.first.id, ctx.first.lock_version, ctx.actor)
    {:ok, editor} = Labels.resource_editor(%{type: "chunk", id: hd(ctx.chunks).id}, ctx.actor)
    row = Enum.find(editor.labels, &(&1.id == ctx.first.id))

    {:ok, _} =
      Labels.edit_resource(
        editor.resource,
        [%{label_id: row.id, operation: "remove", expected_version: row.expected_version}],
        ctx.actor
      )

    assert {:error, :affected_chunks_changed} =
             Reclassification.confirm(
               ctx.first.id,
               ctx.first.lock_version,
               preview.confirmation_token,
               ctx.actor,
               config: Config
             )
  end

  test "a new automatic label creates no backfill reservations", ctx do
    count = Repo.aggregate(Request, :count)

    {:ok, label} =
      Labels.save_definition(
        %{name: "Brand new", targets: ["chunk"], automatic_chunk: true},
        ctx.actor
      )

    assert {:ok, %{affected_chunks: 0}} =
             Reclassification.preview(label.id, label.lock_version, ctx.actor)

    assert Repo.aggregate(Request, :count) == count
  end

  test "confirmation without identity or a configured Decision cannot enqueue", ctx do
    {:ok, preview} = Reclassification.preview(ctx.first.id, ctx.first.lock_version, ctx.actor)
    count = Repo.aggregate(Request, :count)

    assert {:error, :unauthorized} =
             Reclassification.confirm(
               ctx.first.id,
               ctx.first.lock_version,
               preview.confirmation_token,
               nil,
               config: Config
             )

    assert {:ok, _} =
             Zaq.System.save_rag_model_config(:decision, %{credential_id: nil, model: nil})

    assert {:error, :automation_unavailable} =
             Reclassification.confirm(
               ctx.first.id,
               ctx.first.lock_version,
               preview.confirmation_token,
               ctx.actor,
               config: Config
             )

    assert Repo.aggregate(Request, :count) == count
  end
end
