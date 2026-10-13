defmodule Zaq.Channels.LinkedDevice.SessionStorage do
  @moduledoc """
  Node-local, RAM-only messaging records for authorized linked-device runtimes.

  The Channels supervisor initializes a Mnesia `ram_copies` table before starting
  listeners. Records outlive individual listeners, but never a Mnesia/node restart.
  There is no disk schema, checkpoint, replication or durable fallback. Pairing
  credentials belong to the Engine credential document, not this store.

  Callers validate the current credential binding before access. The scope includes
  connector ID, credential ID and profile. Transactions serialize each scope's
  writes, seed and clear; values are bounded to 1 MiB and each scope to 16 MiB.
  This is protocol infrastructure, not a user-facing authorization boundary.
  """
  use GenServer

  @table :zaq_linked_device_sessions
  @max_value_bytes 1024 * 1024
  @max_scope_bytes 16 * 1024 * 1024

  @type scope :: {pos_integer(), pos_integer(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    case :mnesia.create_table(@table,
           attributes: [:key, :value],
           type: :set,
           ram_copies: [node()],
           local_content: true
         ) do
      {:atomic, :ok} -> validate_table()
      {:aborted, {:already_exists, @table}} -> validate_table()
      _ -> {:stop, :storage_unavailable}
    end
  end

  @doc "Executes a bounded record operation after the caller has authorized its scope."
  @spec execute(scope(), map()) ::
          :ok | :error | {:ok, binary() | [String.t()]} | {:error, atom()}
  def execute(scope, request) do
    if valid_request?(request),
      do: transact(fn -> operate(scope, request) end),
      else: {:error, :invalid_request}
  end

  @doc "Seeds a frozen pairing snapshot once, never rolling back an advanced session."
  @spec seed(scope(), %{{String.t(), String.t()} => binary()}) :: :ok | {:error, atom()}
  def seed(scope, records) do
    if Enum.all?(records, fn {{namespace, key}, value} ->
         valid_request?(%{op: :put, namespace: namespace, key: key, value: value})
       end) do
      transact(fn -> seed_once(scope, records) end)
    else
      {:error, :invalid_request}
    end
  end

  defp seed_once(scope, records) do
    unless metadata(scope).seeded do
      Enum.each(records, fn {{namespace, key}, value} ->
        operate(scope, %{op: :put, namespace: namespace, key: key, value: value})
      end)

      write_metadata(scope, %{metadata(scope) | seeded: true})
    end

    :ok
  end

  defp validate_table do
    if :mnesia.wait_for_tables([@table], 5_000) == :ok and
         not :mnesia.system_info(:use_dir) and
         :mnesia.table_info(@table, :storage_type) == :ram_copies and
         :mnesia.table_info(@table, :local_content) and
         :mnesia.table_info(@table, :attributes) == [:key, :value] and
         :mnesia.table_info(@table, :disc_copies) == [] and
         :mnesia.table_info(@table, :disc_only_copies) == [] do
      {:ok, %{}}
    else
      {:stop, :invalid_session_storage}
    end
  end

  defp transact(fun) do
    case :mnesia.transaction(fun, [], 10) do
      {:atomic, result} -> result
      {:aborted, :storage_full} -> {:error, :storage_full}
      {:aborted, _} -> {:error, :storage_unavailable}
    end
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  defp valid_request?(%{op: :clear}), do: true

  defp valid_request?(%{op: :list_keys, namespace: namespace}),
    do: namespace in ["session", "sender_key"]

  defp valid_request?(%{op: :put, value: value} = request),
    do:
      valid_request?(%{request | op: :get}) and is_binary(value) and
        byte_size(value) <= @max_value_bytes

  defp valid_request?(%{op: op, namespace: namespace, key: key}) when op in [:get, :delete],
    do:
      namespace in ["session", "sender_key"] and is_binary(key) and
        byte_size(key) in 1..512 and String.valid?(key)

  defp valid_request?(_), do: false

  defp operate(scope, %{op: :get, namespace: namespace, key: key}),
    do: read({scope, namespace, key})

  defp operate(scope, %{op: :list_keys, namespace: namespace}) do
    keys =
      for {@table, {^scope, ^namespace, key}, _} <-
            :mnesia.match_object(@table, {@table, {scope, namespace, :_}, :_}, :read),
          do: key

    {:ok, Enum.sort(keys)}
  end

  defp operate(scope, %{op: :put, namespace: namespace, key: key, value: value}) do
    meta = metadata(scope)
    address = {scope, namespace, key}
    size = meta.bytes - record_size(address) + :erlang.external_size({namespace, key, value})
    if size > @max_scope_bytes, do: :mnesia.abort(:storage_full)
    :mnesia.write({@table, address, value})
    write_metadata(scope, %{meta | bytes: size, seeded: true})
  end

  defp operate(scope, %{op: :delete, namespace: namespace, key: key}) do
    meta = metadata(scope)
    address = {scope, namespace, key}
    size = meta.bytes - record_size(address)
    :mnesia.delete({@table, address})
    write_metadata(scope, %{meta | bytes: size, seeded: true})
  end

  defp operate(scope, %{op: :clear}) do
    metadata(scope)

    for {@table, key, _} <- :mnesia.match_object(@table, {@table, {scope, :_, :_}, :_}, :write),
        do: :mnesia.delete({@table, key})

    # A late confirmation must not resurrect keys erased by logout.
    write_metadata(scope, %{bytes: 0, seeded: true})
  end

  defp read(key) do
    case :mnesia.read(@table, key, :read) do
      [{@table, ^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  defp record_size({_, namespace, key} = address) do
    case read(address) do
      {:ok, value} -> :erlang.external_size({namespace, key, value})
      :error -> 0
    end
  end

  defp metadata(scope) do
    case :mnesia.read(@table, {scope, :metadata}, :write) do
      [{@table, _, meta}] -> meta
      [] -> %{bytes: 0, seeded: false}
    end
  end

  defp write_metadata(scope, meta), do: :mnesia.write({@table, {scope, :metadata}, meta})
end
