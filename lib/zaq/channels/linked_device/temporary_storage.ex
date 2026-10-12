defmodule Zaq.Channels.LinkedDevice.TemporaryStorage do
  @moduledoc "Bounded, volatile pairing storage. No protocol state is persisted before confirmation."
  use GenServer

  def start_link(profile), do: GenServer.start_link(__MODULE__, profile)
  def init(profile), do: {:ok, %{profile: profile, records: %{}, frozen: false}}
  def new(opts), do: Keyword.fetch!(opts, :pid)

  def get(pid, profile, namespace, key),
    do: call(pid, profile, {:get, {to_string(namespace), key}})

  def put(pid, profile, namespace, key, value),
    do: call(pid, profile, {:put, {to_string(namespace), key}, value})

  def delete(pid, profile, namespace, key),
    do: call(pid, profile, {:delete, {to_string(namespace), key}})

  def clear(pid, profile), do: call(pid, profile, :clear)
  def list_keys(pid, profile, namespace), do: call(pid, profile, {:keys, to_string(namespace)})
  def list_profiles(pid), do: GenServer.call(pid, :profiles)
  @doc "Freezes callbacks atomically with the snapshot, rejecting any late protocol writes."
  def freeze(pid), do: GenServer.call(pid, :freeze)
  def discard(pid), do: GenServer.call(pid, :discard)
  defp call(pid, profile, operation), do: GenServer.call(pid, {profile, operation})

  def handle_call(:profiles, _, state), do: {:reply, {:ok, [state.profile]}, state}
  def handle_call(:freeze, _, state), do: {:reply, state.records, %{state | frozen: true}}
  def handle_call(:discard, _, state), do: {:reply, :ok, %{state | records: %{}, frozen: true}}

  def handle_call({profile, _}, _, %{profile: profile, frozen: true} = state),
    do: {:reply, {:error, :storage_frozen}, state}

  def handle_call({profile, operation}, _, %{profile: profile} = state) do
    {result, records} = operate(operation, state.records)

    if :erlang.external_size(records) <= 8 * 1024 * 1024,
      do: {:reply, result, %{state | records: records}},
      else: {:reply, {:error, :storage_full}, state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_profile}, state}

  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)

  defp operate({:get, key}, records), do: {Map.fetch(records, key), records}
  defp operate({:put, key, value}, records), do: {:ok, Map.put(records, key, value)}
  defp operate({:delete, key}, records), do: {:ok, Map.delete(records, key)}
  defp operate(:clear, _), do: {:ok, %{}}

  defp operate({:keys, namespace}, records),
    do: {{:ok, for({{^namespace, key}, _} <- records, do: key)}, records}
end
