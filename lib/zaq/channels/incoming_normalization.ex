defmodule Zaq.Channels.IncomingNormalization do
  @moduledoc """
  Provider-local normalization of communication facts for the shared chat bridge.

  Implementations interpret transport payloads and emit only normalized facts.
  Facts describe conversations and message identity, not consumer policy.
  Missing or contradictory transport evidence remains unknown.
  """

  @type result :: %{
          conversation_type: :one_to_one | :room,
          source_scope: String.t() | nil,
          provider_sent_at: DateTime.t() | nil
        }

  @callback normalize(map(), map(), term()) ::
              {:ok, result()} | {:error, :unverified_communication_facts}
  @callback source_scope(term()) :: String.t() | nil

  @doc """
  Classifies explicit normalized channel metadata after an adapter sanitizes media.

  Opt in only when the adapter preserves native room/type evidence in normalized
  fields. The shared caller requires empty raw data, nonempty media, matching
  room/type/provider fields, and matching sender/author identifiers. Timestamps
  use Unix seconds, UTC DateTime values, or ISO 8601 strings at this boundary.
  """
  @callback conversation_type(map()) ::
              {:ok, :one_to_one | :room} | {:error, atom()}

  @optional_callbacks conversation_type: 1

  @doc "Returns whether two provider identifiers refer to the same nonempty room."
  def same_room?(value, room) do
    identifier?(value) and identifier?(room) and to_string(value) == to_string(room)
  end

  @doc "Returns whether a value is a usable provider identifier."
  def identifier?(value) when is_binary(value), do: String.trim(value) != ""
  def identifier?(value) when is_integer(value), do: true
  def identifier?(_), do: false
end
