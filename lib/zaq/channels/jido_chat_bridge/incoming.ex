defmodule Zaq.Channels.JidoChatBridge.Incoming do
  @moduledoc """
  Normalization integrations for the installed Jido chat adapters.

  Selection follows the existing provider registration, with no consumer-specific
  configuration. Integrations interpret transport facts only; Engine owns history.

  Integrations may opt into sanitized media normalization through
  `IncomingNormalization.conversation_type/1`. The shared boundary checks
  consistent normalized adapter facts before using that classification, without
  reconstructing raw provider payloads or relaxing native evidence validation.
  """

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}
  alias Zaq.Channels.JidoChatBridge.Incoming.{Discord, Mattermost, Telegram, WhatsApp}

  @integrations %{
    "discord" => Discord,
    "mattermost" => Mattermost,
    "telegram" => Telegram,
    "whatsapp" => WhatsApp
  }

  @doc "Resolves the local normalization integration for an installed adapter."
  def integration(provider), do: Map.get(@integrations, to_string(provider))

  @doc "Normalizes verified transport facts, preserving unknown unsupported inputs."
  @spec normalize(Jido.Chat.Incoming.t(), atom() | String.t(), module()) :: map()
  def normalize(incoming, provider, adapter) do
    case integration(provider) do
      nil ->
        %{}

      module ->
        incoming = enrich(incoming, module, adapter)

        case module.normalize(incoming.channel_meta, incoming.raw || %{}, incoming.timestamp) do
          {:ok, facts} -> facts
          {:error, _} -> sanitized_media_facts(incoming, provider, module)
        end
    end
  end

  # Sanitized media is trusted adapter output. Require mutually consistent
  # normalized facts; absent raw evidence alone must never authorize history.
  defp sanitized_media_facts(
         %Jido.Chat.Incoming{
           raw: raw,
           media: [_ | _],
           external_room_id: room,
           external_user_id: sender,
           author: %{user_id: author},
           chat_type: type,
           channel_meta:
             %{adapter_name: name, chat_type: type, external_room_id: metadata_room} =
               metadata,
           timestamp: timestamp
         },
         provider,
         module
       )
       when is_map(raw) and map_size(raw) == 0 and
              (is_atom(name) or is_binary(name)) and not is_nil(name) do
    with true <- to_string(name) == to_string(provider),
         true <- IncomingNormalization.same_room?(metadata_room, room),
         true <- IncomingNormalization.same_room?(sender, author),
         true <- function_exported?(module, :conversation_type, 1),
         {:ok, kind} <- module.conversation_type(metadata) do
      %{
        conversation_type: kind,
        source_scope: module.source_scope(room),
        sender_id: to_string(author),
        provider_sent_at:
          MessageTimestamp.normalize(timestamp, :second) ||
            MessageTimestamp.normalize(timestamp, :iso8601)
      }
    else
      _ -> %{}
    end
  end

  defp sanitized_media_facts(_, _, _), do: %{}

  defp enrich(incoming, module, adapter) do
    if module && Code.ensure_loaded?(module) && function_exported?(module, :enrich, 2),
      do: module.enrich(incoming, adapter),
      else: incoming
  end

  @doc "Returns the adapter's external message identifier namespace."
  def source_scope(provider, room) do
    case integration(provider) do
      nil -> nil
      module -> module.source_scope(room)
    end
  end
end
