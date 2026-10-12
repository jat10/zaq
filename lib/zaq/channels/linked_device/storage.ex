defmodule Zaq.Channels.LinkedDevice.Storage do
  @moduledoc """
  Profile-scoped term storage backed by the Engine credential document Action.

  State contains only the Engine binding and host profile. Values use uncompressed
  Erlang external terms with safe decoding; keys additionally use Base64 for JSON
  addressing. Corruption returns an error, never a missing-record result. The
  adapter owns stopping protocol operations after storage failure. No callback
  calls a provider process or persists data outside canonical Connect encryption.
  """

  alias Zaq.Event
  alias Zaq.NodeRouter

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

  @doc "Commits a term before reporting success."
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

  @doc "Clears this account's document while retaining its credential association."
  def clear(state, profile), do: call(state, profile, %{op: :clear})

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

  defp call(%{profile: profile, binding: binding}, profile, request) do
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

  defp call(_, _, _), do: {:error, :invalid_profile}
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
