defmodule Zaq.Channels.LinkedDevice.Provider do
  @moduledoc """
  Provider-specific configuration for a linked-device connection.

  The shared integration owns connector identity and credential storage binding.
  Providers translate persisted settings into protocol options; they must not
  start connections or persist secrets while building configuration.
  """

  @callback connection_config(map()) :: {:ok, map()} | {:error, term()}
  @callback storage(map()) :: {module(), keyword()}
  @callback connect(map(), pid()) :: {:ok, term()} | {:error, term()}
  @callback stop(map()) :: :ok | {:error, term()}
  @callback infrastructure_children() :: list()

  @optional_callbacks storage: 1, connect: 2, stop: 1, infrastructure_children: 0
end
