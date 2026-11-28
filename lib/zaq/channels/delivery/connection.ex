defmodule Zaq.Channels.Delivery.Connection do
  @moduledoc "Selects and freezes the committed outbound connection for an attachment attempt."

  alias Zaq.Channels.Bridge

  @doc "Keeps origin identity on Outgoing while selecting the bridge's actual outbound transport."
  def select(outgoing, bridge, opts) do
    with {:ok, origin} <- origin_connection(outgoing),
         :ok <- validate_origin(origin, outgoing.provider),
         {:ok, selected} <- outbound_connection(origin, bridge) do
      details = Bridge.fetch_connection_details_for_config(selected)

      {:ok,
       selected
       |> Map.take([:id, :provider, :kind, :settings])
       |> Map.merge(details)
       |> Map.put(:opts, opts)
       |> Map.put(:delivery_channel_id, outgoing.channel_id)}
    end
  end

  defp origin_connection(%{routing_context: %{channel_config_id: id}})
       when is_integer(id) and id > 0,
       do: Bridge.fetch_channel_config_by_id(id)

  defp origin_connection(%{routing_context: %{channel_config_id: id}}) when not is_nil(id),
    do: {:error, :invalid_connector_id}

  defp origin_connection(outgoing), do: Bridge.fetch_channel_config(outgoing.provider)

  defp validate_origin(config, provider) do
    platform = Bridge.provider_to_bridge_key(config.provider) || config.provider

    if config.kind in [:retrieval, "retrieval"] and
         (to_string(platform) == to_string(provider) or
            to_string(config.provider) == to_string(provider)),
       do: :ok,
       else: {:error, :connector_mismatch}
  end

  defp outbound_connection(origin, bridge) do
    if function_exported?(bridge, :outbound_connection, 1),
      do: bridge.outbound_connection(origin),
      else: {:ok, origin}
  end
end
