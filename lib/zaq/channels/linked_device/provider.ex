defmodule Zaq.Channels.LinkedDevice.Provider do
  @moduledoc """
  Provider-specific configuration for a linked-device connection.

  The shared integration owns connector identity and credential storage binding.
  Providers translate persisted settings into protocol options; they must not
  start connections or persist secrets while building configuration.
  """

  @callback connection_config(map()) :: {:ok, map()} | {:error, term()}
end
