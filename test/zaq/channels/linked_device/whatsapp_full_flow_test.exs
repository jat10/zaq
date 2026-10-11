defmodule Zaq.Channels.LinkedDevice.WhatsAppFullFlowTest do
  @moduledoc """
  QR UI → real adapter decoder → bridge → NodeRouter → Engine admission →
  configured agent → model HTTP → real adapter send/edit → simulated recipient.
  Only the external WhatsApp service and model endpoint are simulated.
  """
  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.LinkedDevice.{Config, Owner}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub, WhatsAppFlowAdapter}
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  @self_jid "15550001@s.whatsapp.net"
  @peer_jid "15550002@s.whatsapp.net"
  @answer "WhatsApp full-flow answer"
  @runtime_keys [
    :channels,
    :node_router,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :pipeline_hooks_module
  ]

  setup %{conn: conn} do
    Zaq.DataCase.isolate_event_registry()
    observer = self()
    previous = Map.new(@runtime_keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@runtime_keys, &Application.delete_env(:zaq, &1))
    Application.put_env(:zaq, :node_router, Zaq.NodeRouter)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device,
        linked_device_provider: Transport
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

    start_supervised!({Transport, observer: observer})

    {server, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          if conn.request_path == "/v1/responses" do
            send(
              observer,
              {:whatsapp_model_input, MultiAgentOpenAIStub.latest_user_message(body)}
            )

            {200, MultiAgentOpenAIStub.text_sse(@answer, "gpt-4.1-mini")}
          else
            {404, %{error: "unexpected model route"}}
          end
        end,
        observer
      )

    start_supervised!(server)
    credential = ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "WhatsApp flow #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => false}
      })

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "WhatsApp full flow",
        provider: "whatsapp",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
        routing_mode: :agent,
        configured_agent_id: agent.id
      })

    {:ok, person} = People.create_person(%{full_name: "WhatsApp sender"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "whatsapp",
        channel_identifier: @peer_jid,
        dm_channel_id: @peer_jid,
        weight: 0
      })

    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    on_exit(fn ->
      ServerManager.stop_server(agent)
      JidoChatBridge.stop_runtime(config)
    end)

    assert :ok = JidoChatBridge.start_runtime(config)
    {:ok, profile} = Config.profile(config)
    %{conn: init_test_session(conn, %{user_id: admin.id}), config: config, profile: profile}
  end

  test "QR pairing and direct message reach the agent and the WhatsApp recipient", context do
    pair_from_ui(context)
    run_message(context, @peer_jid, [])
  end

  test "QR pairing and a group mention reach the agent and the group recipient", context do
    pair_from_ui(context)
    unaddressed = incoming_message("15550003@g.us", [])
    assert :ok = Transport.incoming(context.profile, unaddressed)

    assert eventually(fn -> Repo.get_by(Message, external_message_id: unaddressed.id) != nil end)

    run_message(context, "15550003@g.us", [@self_jid])

    captured = Repo.get_by!(Message, external_message_id: unaddressed.id)
    assert captured.role == "external"
    assert captured.conversation_id == nil
    refute Repo.get_by(ExecutionRecord, user_message_id: captured.id)
    refute_received {:whatsapp_model_input, _}
  end

  defp pair_from_ui(%{conn: conn, config: config, profile: profile}) do
    assert_receive {:whatsapp_connected_config, connection_config}
    assert connection_config.profile == profile
    assert connection_config.sync_history == false
    assert connection_config.sync_full_history == false
    assert {Zaq.Channels.LinkedDevice.WhatsAppStorage, _} = connection_config.storage
    refute Map.has_key?(connection_config, :storage_root)

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/whatsapp")
    view |> element("#pair-config-#{config.id}") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#linked-device-pairing svg[aria-label='Device connection QR code']"
           )

    assert {:ok, %{phase: :pairing, qr: qr}} = Owner.status(profile)
    assert :ok = Transport.scan(profile, qr)

    assert eventually(fn ->
             match?({:ok, %{phase: :connected, qr: nil}}, Owner.status(profile))
           end)

    view |> element("#linked-device-pairing button", "Close") |> render_click()
    view |> element("#pair-config-#{config.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#linked-device-pairing", "Linked device connected")
    refute has_element?(view, "#linked-device-pairing svg")
  end

  defp run_message(%{profile: profile, config: config}, room, mentions) do
    message = incoming_message(room, mentions)

    assert :ok = Transport.incoming(profile, message)
    assert_receive {:whatsapp_model_input, model_input}, 10_000
    assert model_input =~ message.content
    assert_receive {:whatsapp_recipient_received, ^profile, ^room, reply_id, @answer}, 10_000
    assert Transport.mailbox()[{profile, room, reply_id}] == @answer

    assert eventually(fn ->
             Repo.exists?(
               from(e in ExecutionRecord,
                 join: m in Message,
                 on: e.user_message_id == m.id,
                 where: e.status == "completed" and m.external_message_id == ^message.id
               )
             )
           end)

    incoming = Repo.get_by!(Message, external_message_id: message.id, source_provider: "whatsapp")
    assert incoming.role == "user"
    assert is_binary(incoming.conversation_id)

    assert Conversations.get_conversation!(incoming.conversation_id).channel_config_id ==
             config.id

    execution = Repo.get_by!(ExecutionRecord, user_message_id: incoming.id)
    answer = Repo.get!(Message, execution.public_answer_message_id)
    assert answer.conversation_id == incoming.conversation_id
    assert answer.role == "assistant"
    assert answer.content == @answer
  end

  defp incoming_message(room, mentions) do
    id = Ecto.UUID.generate()

    %Amarula.Msg{
      id: id,
      channel: Amarula.Address.parse(room),
      from: Amarula.Address.parse(@peer_jid),
      to: Amarula.Address.parse(@self_jid),
      mentions: Enum.map(mentions, &Amarula.Address.parse/1),
      type: :text,
      content: "WhatsApp question #{id}",
      timestamp: System.system_time(:second),
      raw: %{}
    }
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
