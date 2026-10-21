defmodule Zaq.TestSupport.Channels.Integration.Case do
  @moduledoc """
  ExUnit setup and public helpers for the real communication runtime.

  Use with `async: false` (the default) because current runtime configuration and
  ServerManager are shared. Provider implementations replace external services;
  this case creates real saved fixtures and owns exact configuration restoration.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.Conversations
  alias Zaq.TestSupport.Channels.Integration.{Contract, Fixtures, Observer, Registry, Session}
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub, ToolCallingLLMStub}

  @keys [
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

  using do
    quote do
      use Zaq.DataCase, async: false
      import Zaq.TestSupport.Channels.Integration.Case
      import Zaq.TestSupport.Channels.Integration.Assertions
    end
  end

  @doc "Starts a fake provider, real fixtures and the configured connector runtime."
  @spec channel_session(atom(), keyword()) :: Session.t()
  def channel_session(provider, opts \\ []) do
    driver = Keyword.get_lazy(opts, :driver, fn -> Keyword.fetch!(Registry.all(), provider) end)
    Contract.driver!(provider, driver)
    scope = Ecto.UUID.generate()

    {:ok, handle} =
      Contract.result!(
        provider,
        :start,
        driver.start(owner_pid: self(), scope: scope, provider: provider)
      )

    configure_runtime(handle)
    endpoint = start_llm(scope, opts)
    fixtures = Fixtures.create!(handle, endpoint, scope, opts)
    cleanup(fixtures)

    start_supervised!(
      Supervisor.child_spec(
        {Observer, owner: self(), scope: scope, connector_id: fixtures.connector.id},
        id: {Observer, scope}
      )
    )

    {:ok, connected} = Contract.result!(provider, :connect, driver.connect(handle, fixtures))

    struct!(
      Session,
      Map.merge(
        fixtures |> Map.take([:connector, :person, :agent]),
        %{driver: driver, handle: connected, scope: scope, observer: self()}
      )
    )
  end

  @doc "Emits native input with explicit test-owned source identity and timestamp."
  @spec emit_message(Session.t(), :direct | :shared, keyword()) :: map()
  def emit_message(session, room, opts) do
    spec =
      Map.merge(
        %{
          source_id: Integer.to_string(System.unique_integer([:positive, :monotonic])),
          timestamp: ~U[2026-01-02 03:04:05Z],
          room: room,
          mention?: room == :shared,
          thread_id: nil
        },
        Map.new(opts)
      )

    {:ok, emission} =
      Contract.result!(session.handle.provider, :emit, session.driver.emit(session, spec))

    emission
  end

  @doc "Waits for Channels delivery to finish, including actual Engine confirmation."
  @spec await_exchange(Session.t(), map(), keyword()) :: map()
  def await_exchange(session, emission, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    event = await_delivery(session, emission, System.monotonic_time(:millisecond) + timeout)
    scope = session.scope
    input_id = event.request.metadata[:user_message_id]

    assert_receive {:channel_integration, ^scope, {:runtime_ready, ^input_id}, :return_from, :ok},
                   timeout

    attempts =
      Contract.result!(session.handle.provider, :deliveries, session.driver.deliveries(session))

    assert Enum.all?(attempts, &(&1.channel_config_id == session.connector.id)),
           "#{session.handle.provider}: deliveries crossed connector scope"

    %{event: event, emission: emission, attempts: attempts, reply: event.request}
  end

  @doc "Reads the canonical transcript using the supplied Person's real access policy."
  @spec read_transcript(Session.t(), map(), String.t()) :: term()
  def read_transcript(_session, person, transcript_id),
    do: Conversations.list_canonical_messages(person, transcript_id)

  defp configure_runtime(handle) do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:zaq, &1)})
    on_exit(fn -> Enum.each(previous, &restore_config/1) end)
    Enum.each(@keys -- [:channels], &Application.delete_env(:zaq, &1))
    channels = Application.get_env(:zaq, :channels, %{})

    registration = %{
      bridge: JidoChatBridge,
      adapter: handle.adapter,
      ingress_mode: handle.ingress_mode
    }

    Application.put_env(:zaq, :channels, Map.put(channels, handle.provider, registration))
    Application.put_env(:zaq, :node_router, Zaq.NodeRouter)
  end

  defp restore_config({key, {:ok, value}}), do: Application.put_env(:zaq, key, value)
  defp restore_config({key, :error}), do: Application.delete_env(:zaq, key)

  defp cleanup(fixtures) do
    on_exit(fn ->
      ServerManager.stop_server(fixtures.agent)
      JidoChatBridge.stop_runtime(fixtures.connector)
    end)
  end

  defp start_llm(scope, opts) do
    {child, endpoint} = llm_server(scope, opts)
    start_supervised!(Supervisor.child_spec(child, id: {OpenAIStub, scope}))
    endpoint
  end

  defp llm_server(scope, opts) do
    case Keyword.fetch(opts, :tool_routes) do
      {:ok, routes} ->
        ToolCallingLLMStub.server(routes,
          test_pid: self(),
          final_response: Keyword.fetch!(opts, :llm_final_response)
        )

      :error ->
        text_server(scope, opts)
    end
  end

  defp text_server(scope, opts) do
    owner = self()
    answers = Keyword.get(opts, :answers, [Keyword.get(opts, :llm_answer, "Hello Alice")])

    state =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> answers end}, id: {:llm_answers, scope})
      )

    handler = fn conn, body ->
      assert conn.request_path == "/v1/responses", "unexpected LLM route"
      request = Jason.decode!(body)
      send(owner, {:channel_llm_request, scope, request})

      answer =
        Agent.get_and_update(state, fn
          [answer | rest] -> {answer, rest}
          [] -> flunk("unexpected extra LLM request")
        end)

      {200, MultiAgentOpenAIStub.text_sse(answer, request["model"])}
    end

    OpenAIStub.server(handler, owner)
  end

  defp await_delivery(session, emission, deadline) do
    scope = session.scope
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    assert_receive {:channel_integration, ^scope, :delivery, :return_from, %Zaq.Event{} = event},
                   remaining

    message =
      case event.request.metadata[:user_message_id] do
        nil -> nil
        id -> Zaq.Repo.get(Conversations.Message, id)
      end

    if message && message.external_message_id == emission.source_id do
      event
    else
      await_delivery(session, emission, deadline)
    end
  end
end
