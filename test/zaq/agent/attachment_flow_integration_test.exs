defmodule Zaq.Agent.AttachmentFlowIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Api, as: AgentApi
  alias Zaq.Agent.Executor
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.DataSource.{AttachDocuments, GetDocument}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Storage
  alias Zaq.Storage.{EntryCatalog, VolumeConfig}
  alias Zaq.TestSupport.{DiskConfigFixture, IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}
  alias Zaq.TestSupport.ToolCallingLLMStub

  defmodule DeliveryConfig do
    def get(:zaq, :channels, default, opts) do
      channels = Zaq.Config.get(:zaq, :channels, default, Keyword.delete(opts, :config))

      Map.put(channels, :mattermost, %{
        bridge: Zaq.Channels.JidoChatBridge,
        adapter: Zaq.Test.FileDeliveryAdapter
      })
    end

    def get(app, key, default, opts),
      do: Zaq.Config.get(app, key, default, Keyword.delete(opts, :config))
  end

  setup do
    config = DiskConfigFixture.get_or_create!()
    {:ok, opts} = VolumeConfig.opts_for_channel_config(config)
    volume = opts |> Keyword.fetch!(:storage_config) |> Keyword.fetch!(:default_volume)
    namespace = "attachment-selection-#{Ecto.UUID.generate()}"
    {:ok, root} = Storage.resolve_path(volume, namespace, opts)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for name <- ~w(a.md b.md) do
      File.write!(Path.join(root, name), "Private source bytes: #{name}")
      {:ok, _} = EntryCatalog.ensure(volume, "#{namespace}/#{name}", "file")
    end

    {:ok, folder} = EntryCatalog.ensure(volume, namespace, "directory")
    {:ok, person} = People.create_person(%{full_name: "Attachment reader #{namespace}"})

    {:ok, _} =
      Storage.grant_document_access(folder.id, %{person_id: person.id, access_rights: ["read"]})

    {:ok,
     config: config,
     person: person,
     scope: namespace,
     path: "#{volume}/#{namespace}",
     root: root,
     folder: folder}
  end

  test "real native selection refreshes disk authorization and reaches only Outgoing.attachments",
       context do
    owner = self()

    handler = fn _conn, body ->
      request = MultiAgentOpenAIStub.decode_request!(body)
      results = MultiAgentOpenAIStub.tool_results(request)

      response =
        cond do
          String.contains?(MultiAgentOpenAIStub.latest_user_message(request), "Plain reply") ->
            MultiAgentOpenAIStub.text_sse("Plain reply", "gpt-4.1-mini")

          results == [] ->
            MultiAgentOpenAIStub.tool_call_sse(
              "list_documents",
              %{
                provider: "disk",
                config_id: to_string(context.config.id),
                path: context.path
              },
              call_id: "list"
            )

          length(results) in 1..4 ->
            [listing | _] = results
            assert listing.output["ok"] == true
            files = listing.output["result"]["records"]
            [a] = Enum.filter(files, &(&1["name"] == "a.md"))
            [b] = Enum.filter(files, &(&1["name"] == "b.md"))

            {operation, file} =
              case length(results) do
                1 -> {"add", a}
                2 -> {"add", %{b | "id" => "tampered"}}
                3 -> {"add", b}
                4 -> {"remove", a}
              end

            assert String.starts_with?(file["provenance_ref"], "prov_")
            if length(results) != 2, do: send(owner, {:selected, operation, file["id"]})

            MultiAgentOpenAIStub.tool_call_sse(
              "attach_documents",
              %{operation: operation, records: [file]},
              call_id: "select_#{length(results)}"
            )

          true ->
            assert Enum.map(results, & &1.output["ok"]) == [true, true, false, true, true]
            MultiAgentOpenAIStub.text_sse("Selected the requested files.", "gpt-4.1-mini")
        end

      {200, response}
    end

    {child, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child)

    agent =
      IntegrationAgent.create!(
        endpoint,
        context.scope,
        "Select documents.",
        ~w(data_source.list_documents data_source.attach_document)
      )

    incoming = %Incoming{
      content: "Select A, select B, remove A",
      provider: :web,
      channel_id: context.scope,
      person: context.person
    }

    outgoing = Executor.run(incoming, agent_id: to_string(agent.id), scope: context.scope)
    assert outgoing.metadata.error == false, inspect(outgoing.metadata)
    assert outgoing.body == "Selected the requested files."
    assert_receive {:selected, "add", a}
    assert_receive {:selected, "add", b}
    assert_receive {:selected, "remove", ^a}
    assert [%{id: ^b, name: "b.md", content: nil} = selected] = outgoing.attachments
    assert {:ok, %{"provider" => "disk", "config_id" => config_id}} = Provenance.verify(selected)
    assert config_id == context.config.id
    assert is_binary(selected.materialization_handle)
    refute Map.has_key?(outgoing.metadata, :attachments)
    evidence = Jason.encode!(Map.take(outgoing.metadata, [:tool_calls, :trace]))
    refute evidence =~ selected.provenance_ref
    refute evidence =~ selected.materialization_handle
    refute evidence =~ "Private source bytes"
    assert File.read!(Path.join(context.root, "b.md")) == "Private source bytes: b.md"

    delivery = Zaq.ChannelDeliveryFixtures.stored_channel_answer(person: context.person)

    delivery.config
    |> ChannelConfig.changeset(%{
      token: self() |> :erlang.pid_to_list() |> List.to_string()
    })
    |> Zaq.Repo.update!()

    routed = %{
      outgoing
      | provider: :mattermost,
        channel_id: "room",
        routing_context: %{channel_config_id: delivery.config.id, conversation_type: :room},
        metadata: %{
          user_message_id: delivery.input.id,
          assistant_message_id: delivery.answer.id,
          persisted_assistant_message_id: delivery.answer.id
        }
    }

    File.rm!(Path.join(context.root, "a.md"))

    event =
      Event.new(routed, :channels,
        actor: %{person: %{id: context.person.id}},
        opts: [action: :deliver_outgoing, config: DeliveryConfig]
      )

    assert %{response: {:ok, %{message_id: delivered_id}}} = NodeRouter.dispatch(event)
    assert_receive {:adapter_upload, %{files: [%{filename: "b.md", data: bytes}]}}
    assert bytes == "Private source bytes: b.md"
    assert_receive {:adapter_send, "room", "Selected the requested files.", _}
    refute_received {:adapter_upload, _}
    refute_received {:adapter_send, _, _, _}
    saved = Repo.get!(Message, delivery.answer.id)
    assert saved.metadata["delivery_confirmation"]["message_id"] == delivered_id
    assert [%{"name" => "b.md"}] = saved.attachments

    next =
      Executor.run(%{incoming | content: "Plain reply", attachments: [selected]},
        agent_id: to_string(agent.id),
        scope: context.scope
      )

    assert next.metadata.error == false
    assert next.attachments == []
    assert next.body == "Plain reply"

    for _ <- 1..7 do
      assert_receive {:openai_request, "POST", "/v1/responses", _, request_body}
      refute request_body =~ selected.provenance_ref
      refute request_body =~ selected.materialization_handle
      refute request_body =~ "Private source bytes"
    end
  end

  test "signed disk metadata is refreshed and a revoked source grant cannot select", context do
    {:ok, entry} =
      EntryCatalog.ensure(
        context.path |> String.split("/") |> hd(),
        "#{context.scope}/a.md",
        "file"
      )

    actor = %{person: %{id: context.person.id}}

    trusted = %{
      actor: actor,
      request_id: "request",
      state: %{requests: %{"request" => %{status: :pending}}}
    }

    assert {:ok, %{record: old}} =
             ActionContract.execute(
               GetDocument,
               %{
                 provider: "disk",
                 config_id: to_string(context.config.id),
                 document_id: entry.id
               },
               trusted
             )

    assert {:ok, %{records: [%{id: id, content: nil}]}} =
             ActionContract.execute(AttachDocuments, %{operation: "add", records: [old]}, trusted)

    assert id == entry.id

    assert {:ok, _} =
             Storage.replace_document_grants(context.folder.id, [], skip_permissions: true)

    assert {:error, _} =
             ActionContract.execute(AttachDocuments, %{operation: "add", records: [old]}, trusted)

    assert File.read!(Path.join(context.root, "a.md")) == "Private source bytes: a.md"
  end

  test "Agent role retains authorized files in its legacy configured response", context do
    volume = context.path |> String.split("/") |> hd()
    {:ok, entry} = EntryCatalog.ensure(volume, "#{context.scope}/a.md", "file")
    actor = %{person: %{id: context.person.id}}

    assert {:ok, %{record: record}} =
             ActionContract.execute(
               GetDocument,
               %{
                 provider: "disk",
                 config_id: to_string(context.config.id),
                 document_id: entry.id
               },
               %{actor: actor}
             )

    routes = [
      %{
        match: fn _ -> true end,
        tool: "attach_documents",
        arguments: fn _ -> %{operation: "add", records: [record]} end
      }
    ]

    {child, endpoint} =
      ToolCallingLLMStub.server(routes, final_response: "Selected for delivery.")

    start_supervised!(child)

    incoming = %Incoming{
      content: "Select this document",
      provider: nil,
      channel_id: context.scope,
      person: context.person
    }

    scope = Executor.derive_scope(incoming, actor)

    agent =
      IntegrationAgent.create!(endpoint, scope, "Select authorized files.", [
        "data_source.attach_document"
      ])

    event = Event.new(incoming, :agent, actor: actor, opts: [action: :run_pipeline])
    event = %{event | assigns: %{"agent_selection" => %{"agent_id" => agent.id}}}

    assert %{response: outgoing, actor: returned_actor} =
             AgentApi.handle_event(event, :run_pipeline, nil)

    assert returned_actor.person.id == context.person.id
    assert outgoing.metadata.error == false
    assert outgoing.body == "Selected for delivery."
    assert [%{id: id}] = outgoing.attachments
    assert id == entry.id
  end

  test "a real native provider failure after successful selection returns no attachments",
       context do
    handler = fn _conn, body ->
      request = MultiAgentOpenAIStub.decode_request!(body)
      results = MultiAgentOpenAIStub.tool_results(request)

      case results do
        [] ->
          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "list_documents",
             %{
               provider: "disk",
               config_id: to_string(context.config.id),
               path: context.path
             },
             call_id: "list"
           )}

        [listing] ->
          [file | _] = listing.output["result"]["records"]

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "attach_documents",
             %{operation: "add", records: [file]},
             call_id: "select"
           )}

        [_, selection] ->
          assert selection.output["ok"] == true
          {400, Jason.encode!(%{error: %{message: "forced provider failure"}})}
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child)

    agent =
      IntegrationAgent.create!(
        endpoint,
        context.scope,
        "Select documents.",
        ~w(data_source.list_documents data_source.attach_document)
      )

    incoming = %Incoming{
      content: "Select",
      provider: :web,
      channel_id: context.scope,
      person: context.person
    }

    outgoing = Executor.run(incoming, agent_id: to_string(agent.id), scope: context.scope)
    assert outgoing.metadata.error == true
    assert outgoing.attachments == []

    assert Enum.any?(
             outgoing.metadata.tool_calls,
             &(&1["name"] == "attach_documents" and &1["outcome"] == "succeeded")
           )
  end
end
