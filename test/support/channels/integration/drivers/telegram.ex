defmodule Zaq.TestSupport.Channels.Integration.Drivers.Telegram do
  @moduledoc """
  Native Telegram webhooks and a loopback Bot API for real channel integration.

  The actual Telegram adapter parses updates and sends through ExGram's HTTP
  adapter to the saved local URL. No Telegram transport or ZAQ internal is replaced.
  Numeric message ids remain scoped to their native chat and connector.
  """
  @behaviour Zaq.TestSupport.Channels.Integration.Driver

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.TestSupport.Channels.Integration.ProviderState
  alias Zaq.TestSupport.OpenAIStub

  @impl true
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner_pid)
    scope = Keyword.fetch!(opts, :scope)

    state =
      start_supervised!(
        Supervisor.child_spec(
          {ProviderState, provider: :telegram, owner: owner, scope: scope, id_prefix: "100000"},
          id: {__MODULE__, scope}
        )
      )

    {child, endpoint} = OpenAIStub.server(&http(&1, &2, state, owner, scope), owner)
    start_supervised!(Supervisor.child_spec(child, id: {__MODULE__, scope, :http}))

    {:ok,
     %{
       provider: :telegram,
       adapter: Jido.Chat.Telegram.Adapter,
       ingress_mode: :webhook,
       connector_attrs: %{
         url: String.trim_trailing(endpoint, "/v1"),
         token: "synthetic-token",
         settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "999"}}
       },
       sender: %{
         id: Integer.to_string(1_000_000 + System.unique_integer([:positive, :monotonic]))
       },
       rooms: %{direct: "123", shared: "-100123"},
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
    channel = Map.fetch!(session.handle.rooms, spec.room)
    mention? = Map.get(spec, :mention?, false) and spec.room == :shared
    text = if mention?, do: "@zaq " <> spec.content, else: spec.content

    message = %{
      "message_id" => String.to_integer(spec.source_id),
      "date" => DateTime.to_unix(spec.timestamp),
      "chat" => %{
        "id" => String.to_integer(channel),
        "type" => if(spec.room == :direct, do: "private", else: "supergroup")
      },
      "from" => %{
        "id" => String.to_integer(Map.get(spec, :sender, session.handle.sender.id)),
        "username" => "alice",
        "first_name" => "Alice",
        "is_bot" => false
      },
      "text" => text,
      "entities" =>
        if(mention?, do: [%{"type" => "mention", "offset" => 0, "length" => 4}], else: [])
    }

    message =
      if spec.thread_id,
        do: Map.put(message, "message_thread_id", String.to_integer(spec.thread_id)),
        else: message

    request = %{
      "method" => "POST",
      "path" => "/channels/webhook/conversation/telegram",
      "headers" => %{},
      "query" => %{},
      "payload" => %{"update_id" => System.unique_integer([:positive]), "message" => message}
    }

    case JidoChatBridge.handle_webhook(session.connector, request) do
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
  def capabilities do
    %{
      direct: true,
      shared: true,
      threads: true,
      edits: true,
      thread_root_lookup:
        {:unsupported, "Telegram Bot API cannot fetch an arbitrary root message"}
    }
  end

  defp http(conn, body, state, owner, scope) do
    payload = decode_body(body)
    method = conn.request_path |> String.split("/", trim: true) |> List.last()

    case {conn.method, method} do
      {"POST", name} when name in ["sendMessage", "sendRichMessage"] ->
        post(state, :send, payload)

      {"POST", "editMessageText"} ->
        post(state, :edit, payload)

      {"POST", "sendChatAction"} ->
        typing(state, payload)

      {"POST", "getChat"} ->
        ok(chat(payload["chat_id"]))

      {"POST", "getMe"} ->
        ok(%{"id" => 999, "is_bot" => true, "username" => "zaq", "first_name" => "ZAQ"})

      {"POST", name} when name in ["setWebhook", "deleteWebhook"] ->
        ok(true)

      {"POST", "getWebhookInfo"} ->
        ok(%{"url" => "", "has_custom_certificate" => false, "pending_update_count" => 0})

      other ->
        send(owner, {:channel_provider_unexpected, scope, other})

        {500,
         %{
           "ok" => false,
           "error_code" => 500,
           "description" => "Unexpected fake Telegram request"
         }}
    end
  end

  defp post(state, operation, payload) do
    text = get_in(payload, ["rich_message", "markdown"]) || payload["text"]
    previous = ProviderState.message(state, optional_id(payload["message_id"])) || %{}
    thread = payload["message_thread_id"] || previous["message_thread_id"]

    attrs = %{
      operation: operation,
      channel_id: to_string(payload["chat_id"]),
      thread_id: optional_id(thread),
      message_id: optional_id(payload["message_id"]),
      text: text,
      native_payload: payload
    }

    case ProviderState.attempt(state, attrs) do
      {:ok, id} ->
        delivered = %{
          "message_id" => String.to_integer(id),
          "date" => 1_767_323_045,
          "chat" => chat(payload["chat_id"]),
          "text" => text,
          "message_thread_id" => thread
        }

        :ok = ProviderState.remember(state, id, delivered)
        ok(delivered)

      {:error, reason} ->
        failure(reason)
    end
  end

  defp typing(state, payload) do
    case ProviderState.attempt(state, %{
           operation: :typing,
           channel_id: to_string(payload["chat_id"]),
           native_payload: payload
         }) do
      {:ok, _} -> ok(true)
      {:error, reason} -> failure(reason)
    end
  end

  defp chat(id),
    do: %{
      "id" => String.to_integer(to_string(id)),
      "type" => if(String.starts_with?(to_string(id), "-"), do: "supergroup", else: "private"),
      "first_name" => "Alice"
    }

  defp ok(result), do: {200, %{"ok" => true, "result" => result}}

  defp failure(reason),
    do: {503, %{"ok" => false, "error_code" => 503, "description" => "Synthetic #{reason}"}}

  defp optional_id(nil), do: nil
  defp optional_id(id), do: to_string(id)
  defp decode_body(""), do: %{}
  defp decode_body(body), do: Jason.decode!(body)
end
