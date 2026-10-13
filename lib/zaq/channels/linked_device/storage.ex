defmodule Zaq.Channels.LinkedDevice.Storage do
  @moduledoc """
  Profile-scoped protocol storage with durable pairing and volatile messaging state.

  State contains only the Engine binding and host profile. Values use uncompressed
  Erlang external terms with safe decoding; keys additionally use Base64 for JSON
  addressing. Corruption returns an error, never a missing-record result. The
  adapter owns stopping protocol operations after storage failure. No callback
  calls a provider process. Pairing and supporting protocol records use canonical
  Connect encryption. The `session` and `sender_key` namespaces use node-local
  RAM-only Mnesia after revalidating the current Engine binding on every callback.
  They never fall back to old database state after a restart.
  """

  alias Zaq.Channels.LinkedDevice.SessionStorage
  alias Zaq.Event
  alias Zaq.NodeRouter

  @volatile_namespaces ["session", "sender_key"]

  @type state :: %{binding: map(), profile: String.t()}

  @doc "Creates a callback context; it has no transient protocol state."
  def new(opts),
    do: %{binding: Keyword.fetch!(opts, :binding), profile: Keyword.fetch!(opts, :profile)}

  @doc "Reads one stored term, distinguishing absence from invalid state."
  def get(state, profile, namespace, key) do
    case call(state, profile, %{op: :get, namespace: to_string(namespace), key: encode(key)}) do
      {:ok, value} -> decode(value)
      result -> result
    end
  rescue
    _ -> {:error, :invalid_state}
  end

  @doc "Commits a term to its namespace's store before reporting success."
  def put(state, profile, namespace, key, value),
    do:
      call(state, profile, %{
        op: :put,
        namespace: to_string(namespace),
        key: encode(key),
        value: encode(value)
      })

  @doc "Deletes one term idempotently."
  def delete(state, profile, namespace, key),
    do: call(state, profile, %{op: :delete, namespace: to_string(namespace), key: encode(key)})

  @doc "Clears this account's durable and RAM records, retaining its credential association."
  def clear(state, profile) do
    with :ok <- call(state, profile, %{op: :clear}),
         do: SessionStorage.execute(scope(state), %{op: :clear})
  end

  @doc "Removes obsolete database sessions before starting a saved connector."
  @spec prepare(state()) :: :ok | {:error, atom()}
  def prepare(state) do
    with {:ok, _} <- call(state, state.profile, %{op: :list_keys, namespace: "session"}) do
      Enum.reduce_while(@volatile_namespaces, :ok, &delete_durable_namespace(state, &1, &2))
    end
  end

  defp delete_durable_namespace(state, namespace, :ok) do
    case document_call(state, %{op: :delete_namespace, namespace: namespace}) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc "Selects the frozen protocol records that require encrypted persistence."
  @spec durable_records(map()) :: map()
  def durable_records(records),
    do:
      Map.reject(records, fn {{namespace, _}, _} ->
        to_string(namespace) in @volatile_namespaces
      end)

  @doc "Transfers a confirmed pairing's volatile records before the normal runtime starts."
  @spec seed(state(), map()) :: :ok | {:error, atom()}
  def seed(state, records) do
    with {:ok, _} <- authorize(state) do
      encoded =
        for {{namespace, key}, value} <- records,
            to_string(namespace) in @volatile_namespaces,
            into: %{},
            do: {{to_string(namespace), encode(key)}, encode(value)}

      SessionStorage.seed(scope(state), encoded)
    end
  end

  @doc "Lists only the authorized profile after revalidating its binding."
  def list_profiles(state) do
    with {:ok, _} <- call(state, state.profile, %{op: :list_keys, namespace: "__binding_check__"}),
         do: {:ok, [state.profile]}
  end

  @doc "Lists decoded keys within one namespace."
  def list_keys(state, profile, namespace) do
    with {:ok, keys} <- call(state, profile, %{op: :list_keys, namespace: to_string(namespace)}) do
      Enum.reduce_while(keys, {:ok, []}, &decode_key/2)
    end
  end

  defp decode_key(key, {:ok, acc}) do
    case decode(key) do
      {:ok, term} -> {:cont, {:ok, acc ++ [term]}}
      error -> {:halt, error}
    end
  end

  defp call(%{profile: profile} = state, profile, request) do
    if request[:namespace] in @volatile_namespaces do
      with {:ok, _} <- authorize(state), do: SessionStorage.execute(scope(state), request)
    else
      document_call(state, request)
    end
  end

  defp call(_, _, _), do: {:error, :invalid_profile}

  defp authorize(state),
    do: document_call(state, %{op: :list_keys, namespace: "__binding_check__"})

  defp scope(%{binding: binding, profile: profile}),
    do: {binding.channel_config_id, binding.credential_id, profile}

  defp document_call(%{binding: binding}, request) do
    request
    |> Map.put(:binding, binding)
    |> Event.new(:engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch(%{
      rpc_call_with_timeout_fn: fn node, module, function, args, _ ->
        :rpc.call(node, module, function, args, 6_000)
      end
    })
    |> Map.fetch!(:response)
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

  defp decode(value) do
    with {:ok, <<131, tag, _::binary>> = bytes} when tag != 80 <- Base.decode64(value),
         term <- :erlang.binary_to_term(bytes, [:safe]) do
      {:ok, term}
    else
      _ -> {:error, :invalid_state}
    end
  rescue
    _ -> {:error, :invalid_state}
  end
end
