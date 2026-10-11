defmodule Zaq.Channels.LinkedDevice.WhatsAppStorage do
  @moduledoc """
  Amarula storage translation into confidential Engine request/response events.

  Only this module serializes Amarula terms. The Engine stores opaque encrypted
  values, independent of WhatsApp. Storage failures shut down the caller rather than
  masquerading as absent credentials or successful writes. Amarula ignores some
  write return values; a shutdown prevents it continuing with unpersisted state and
  avoids abnormal GenServer crash reports containing protocol secrets. No callback may
  call an Amarula process: its session custodian may hold a lock while awaiting us.
  """
  use Amarula.Storage.Adapter

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl true
  def new(opts), do: %{binding: Keyword.fetch!(opts, :binding)}

  @impl true
  def get(state, profile, namespace, key) do
    case call(state, profile, %{op: :get, namespace: to_string(namespace), key: encode(key)}) do
      {:ok, value} -> {:ok, decode(value)}
      :error -> :error
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  end

  @impl true
  def put(state, profile, namespace, key, value),
    do:
      call(state, profile, %{
        op: :put,
        namespace: to_string(namespace),
        key: encode(key),
        value: encode(value)
      })
      |> confirm_write()

  @impl true
  def delete(state, profile, namespace, key),
    do:
      call(state, profile, %{op: :delete, namespace: to_string(namespace), key: encode(key)})
      |> confirm_write()

  @impl true
  def clear(state, profile), do: call(state, profile, %{op: :clear}) |> confirm_write()

  @impl true
  def list_profiles(state), do: call(state, state.binding.profile, %{op: :list_profiles})

  @impl true
  def list_keys(state, profile, namespace) do
    with {:ok, keys} <- call(state, profile, %{op: :list_keys, namespace: to_string(namespace)}) do
      {:ok, Enum.map(keys, &decode/1)}
    end
  end

  defp call(%{binding: %{profile: profile} = binding}, profile, request) do
    event =
      Event.new(Map.put(request, :binding, binding), :engine,
        opts: [action: :linked_device_storage, confidential: true, linked_device_runtime: true]
      )

    NodeRouter.dispatch(event, %{
      rpc_call_with_timeout_fn: fn node, module, function, args, _timeout ->
        :rpc.call(node, module, function, args, 750)
      end
    }).response
  rescue
    _ -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp call(_state, _profile, _request),
    do: unavailable()

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()
  defp decode(value), do: value |> Base.decode64!() |> :erlang.binary_to_term([:safe])

  defp confirm_write(:ok), do: :ok
  defp confirm_write(_), do: unavailable()
  defp unavailable, do: exit({:shutdown, :linked_device_storage_unavailable})
end
