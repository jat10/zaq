defmodule Zaq.TestSupport.Channels.Integration.Drivers.Mattermost do
  @moduledoc """
  Native Mattermost frame ingress and loopback REST service for ZAQ integration.

  The frame boundary reuses MattermostHistoryFixture; TCP/WebSocket reconnection
  is outside this suite. Real adapter/bridge parsing, routing and delivery run.
  The fake provides profiles, room membership, roots and send/edit/typing APIs.
  """
  @behaviour Zaq.TestSupport.Channels.Integration.Driver

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.TestSupport.Channels.Integration.ProviderState
  alias Zaq.TestSupport.{MattermostHistoryFixture, OpenAIStub}

  @impl true
  def start(opts) do
    configure_bot_identity()
    owner = Keyword.fetch!(opts, :owner_pid)
    scope = Keyword.fetch!(opts, :scope)

    state =
      start_supervised!(
        Supervisor.child_spec(
          {ProviderState, provider: :mattermost, owner: owner, scope: scope},
          id: {__MODULE__, scope}
        )
      )

    sender = scope |> String.replace("-", "") |> String.slice(0, 26)
    :ok = ProviderState.remember(state, "_sender", %{"id" => sender})

    {child, endpoint} = OpenAIStub.server(&http(&1, &2, state, owner, scope), owner)
    start_supervised!(Supervisor.child_spec(child, id: {__MODULE__, scope, :http}))

    {:ok,
     %{
       provider: :mattermost,
       adapter: Jido.Chat.Mattermost.Adapter,
       ingress_mode: :webhook,
       connector_attrs: %{
         url: String.trim_trailing(endpoint, "/v1"),
         token: "synthetic-token",
         settings: %{
           "jido_chat" => %{
             "bot_name" => "zaq",
             "bot_user_id" => "bot",
             "room_reply_policy" => "mention_required"
           }
         }
       },
       sender: %{id: sender},
       rooms: %{direct: "alice-dm", shared: "abcdefghijklmnopqrstuvwx12"},
       opaque: state
     }}
  end

  @impl true
  def connect(handle, context) do
    :ok = ProviderState.bind(handle.opaque, context.connector.id)
    with :ok <- JidoChatBridge.start_runtime(context.connector), do: {:ok, handle}
  end

  @impl true
  def emit(session, spec) do
    handle = session.handle
    channel = Map.fetch!(handle.rooms, spec.room)
    mention? = Map.get(spec, :mention?, false)
    text = if mention? and spec.room == :shared, do: "@zaq " <> spec.content, else: spec.content

    attrs = %{
      "id" => spec.source_id,
      "user_id" => Map.get(spec, :sender, handle.sender.id),
      "channel_id" => channel,
      "message" => text,
      "root_id" => spec.thread_id || "",
      "create_at" => DateTime.to_unix(spec.timestamp, :millisecond),
      "props" => %{"mentions" => if(mention?, do: ["bot"], else: [])}
    }

    :ok = ProviderState.remember(handle.opaque, spec.source_id, attrs)

    {result, _post} =
      case spec.room do
        :direct -> MattermostHistoryFixture.direct_post(session.connector, attrs)
        :shared -> MattermostHistoryFixture.post(session.connector, nil, mention?, attrs)
      end

    case result do
      {:ok, _} ->
        {:ok, %{source_id: spec.source_id, channel_id: channel, thread_id: spec.thread_id}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def script(session, script), do: ProviderState.script(session.handle.opaque, script)

  @impl true
  def deliveries(session), do: ProviderState.deliveries(session.handle.opaque)

  @impl true
  def capabilities,
    do: %{direct: true, shared: true, threads: true, thread_root_lookup: true, edits: true}

  defp http(conn, body, state, owner, scope) do
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    case {conn.method, String.split(conn.request_path, "/", trim: true)} do
      {"GET", path} ->
        get_response(path, state, owner, scope)

      {"POST", ["api", "v4", "channels", "direct"]} ->
        {201, %{"id" => "alice-dm", "type" => "D"}}

      {"POST", ["api", "v4", "posts"]} ->
        post(state, :send, payload)

      {"PUT", ["api", "v4", "posts", id]} ->
        post(state, :edit, Map.put(payload, "id", id))

      {"POST", ["api", "v4", "users", "me", "typing"]} ->
        typing(state, payload)

      other ->
        unexpected(owner, scope, other)
    end
  end

  defp get_response(path, state, owner, scope) do
    case path do
      ["api", "v4", "users", id] ->
        {200,
         %{
           "id" => id,
           "username" => if(id == "bot", do: "zaq", else: id),
           "first_name" => id,
           "email" => "#{id}@example.test"
         }}

      ["api", "v4", "posts", id] ->
        root_response(state, id)

      ["api", "v4", "channels", id] ->
        {200, %{"id" => id, "type" => "O", "name" => id}}

      ["api", "v4", "channels", _, "members"] ->
        sender = ProviderState.message(state, "_sender")
        {200, [%{"user_id" => sender["id"]}, %{"user_id" => "bot"}]}

      _ ->
        unexpected(owner, scope, {"GET", path})
    end
  end

  defp typing(state, payload) do
    case ProviderState.attempt(state, %{
           operation: :typing,
           channel_id: payload["channel_id"],
           native_payload: payload
         }) do
      {:ok, _} -> {200, %{}}
      {:error, reason} -> {503, %{"message" => "Synthetic #{reason}"}}
    end
  end

  defp unexpected(owner, scope, request) do
    send(owner, {:channel_provider_unexpected, scope, request})
    {500, %{"message" => "Unexpected fake Mattermost request"}}
  end

  defp post(state, operation, payload) do
    previous = ProviderState.message(state, payload["id"]) || %{}
    post = Map.merge(previous, payload)

    attrs = %{
      operation: operation,
      channel_id: post["channel_id"],
      thread_id: blank_to_nil(post["root_id"]),
      message_id: post["id"],
      text: payload["message"],
      native_payload: payload
    }

    case ProviderState.attempt(state, attrs) do
      {:ok, id} ->
        delivered =
          Map.merge(post, %{"id" => id, "user_id" => "bot", "create_at" => 1_700_000_000_001})

        :ok = ProviderState.remember(state, id, delivered)
        {if(operation == :send, do: 201, else: 200), delivered}

      {:error, reason} ->
        {503, %{"message" => "Synthetic #{reason}"}}
    end
  end

  defp root_response(state, id) do
    case ProviderState.message(state, id) do
      nil -> {404, %{"message" => "Post not found"}}
      post -> {200, post}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp configure_bot_identity do
    previous =
      for key <- [:bot_name, :bot_user_id],
          do: {key, Application.fetch_env(:jido_chat_mattermost, key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:jido_chat_mattermost, key, value)
        {key, :error} -> Application.delete_env(:jido_chat_mattermost, key)
      end)
    end)

    Application.put_env(:jido_chat_mattermost, :bot_name, "zaq")
    Application.put_env(:jido_chat_mattermost, :bot_user_id, "bot")
  end
end
