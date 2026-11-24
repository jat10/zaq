defmodule Zaq.Channels.JidoChatBridge.AdapterOptions do
  @moduledoc """
  Builds shared connection options for jido_chat adapters. Each selected adapter
  resolves which forwarded settings apply to its requirements and transport.
  """

  @doc "Returns shared adapter options from a connection map or config for any provider."
  @spec build(atom() | String.t() | nil, map()) :: keyword()
  def build(_provider, connection) when is_map(connection) do
    settings = value(connection, :settings) || %{}

    [url: value(connection, :url), token: value(connection, :token)]
    |> maybe_put(:transport, value(connection, :transport))
    |> maybe_put(
      :max_file_size,
      value(connection, :max_file_size) || value(settings, :max_file_size)
    )
    |> maybe_put(
      :max_upload_request_size,
      value(connection, :max_upload_request_size) || value(settings, :max_upload_request_size)
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp value(connection, key),
    do: Map.get(connection, key) || Map.get(connection, Atom.to_string(key))
end
