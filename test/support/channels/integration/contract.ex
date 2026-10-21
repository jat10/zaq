defmodule Zaq.TestSupport.Channels.Integration.Contract do
  @moduledoc """
  Executable driver contract with provider/operation-specific failure messages.

  Checks callback availability and observable result shapes. The integration
  suite separately proves native parsing, agent execution and persisted history.
  Error tuples remain errors; malformed results raise an ExUnit assertion.
  """

  import ExUnit.Assertions

  alias Zaq.TestSupport.Channels.Integration.Driver

  @optional [:threads, :thread_root_lookup, :edits]
  @handle_fields [:provider, :adapter, :ingress_mode, :connector_attrs, :sender, :rooms, :opaque]
  @delivery_fields [
    :sequence,
    :operation,
    :provider,
    :channel_config_id,
    :channel_id,
    :thread_id,
    :message_id,
    :text,
    :outcome,
    :native_payload
  ]

  @doc "Checks required callbacks before evaluating the driver's capabilities."
  @spec driver!(atom(), module()) :: Driver.capabilities()
  def driver!(provider, driver) do
    assert Code.ensure_loaded?(driver), "#{provider}: driver #{inspect(driver)} is unavailable"

    for {callback, arity} <- Driver.behaviour_info(:callbacks) do
      assert function_exported?(driver, callback, arity),
             "#{provider}: missing #{callback}/#{arity} on #{inspect(driver)}"
    end

    behaviours =
      driver.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Driver in behaviours, "#{provider}: #{inspect(driver)} must declare @behaviour Driver"
    capabilities!(provider, driver.capabilities())
  end

  @doc "Required direct/shared support cannot be switched off; extras need explicit evidence."
  @spec capabilities!(atom(), term()) :: Driver.capabilities()
  def capabilities!(provider, capabilities) do
    assert is_map(capabilities), "#{provider}: invalid capabilities map"

    for required <- [:direct, :shared] do
      assert Map.get(capabilities, required) == true,
             "#{provider}: capabilities must support #{required}"
    end

    for optional <- @optional do
      assert supported_or_explained?(Map.get(capabilities, optional)),
             "#{provider}: capabilities #{optional} requires true or {:unsupported, reason}"
    end

    capabilities
  end

  @doc "Validates a callback's public result without converting errors to success."
  @spec result!(atom(), atom(), term()) :: term()
  def result!(_provider, operation, {:error, _} = result)
      when operation in [:start, :connect, :emit, :script], do: result

  def result!(provider, operation, {:ok, handle} = result) when operation in [:start, :connect] do
    assert handle?(handle, provider), "#{provider}: invalid #{operation} result (driver handle)"
    result
  end

  def result!(provider, :emit, {:ok, emission} = result) do
    assert is_map(emission) and nonempty?(emission[:source_id]) and
             nonempty?(emission[:channel_id]) and Map.has_key?(emission, :thread_id) and
             optional_id?(emission.thread_id),
           "#{provider}: invalid emit result (native source/room coordinates)"

    result
  end

  def result!(_provider, :script, :ok), do: :ok

  def result!(provider, :deliveries, deliveries) when is_list(deliveries) do
    assert Enum.all?(deliveries, &delivery?(&1, provider)),
           "#{provider}: invalid deliveries result (recorded provider attempts)"

    sequences = Enum.map(deliveries, & &1.sequence)

    assert sequences == Enum.sort(Enum.uniq(sequences)),
           "#{provider}: deliveries must have unique increasing sequences"

    deliveries
  end

  def result!(provider, operation, _result), do: flunk("#{provider}: invalid #{operation} result")

  defp handle?(handle, provider) when is_map(handle) do
    Enum.all?(@handle_fields, &Map.has_key?(handle, &1)) and handle.provider == provider and
      handle_configuration?(handle) and rooms?(handle.rooms)
  end

  defp handle?(_, _), do: false

  defp delivery?(attempt, provider) when is_map(attempt) do
    Enum.all?(@delivery_fields, &Map.has_key?(attempt, &1)) and attempt.provider == provider and
      positive?(attempt.sequence) and attempt.operation in [:send, :edit, :typing] and
      delivery_coordinates?(attempt) and delivery_content?(attempt) and delivery_outcome?(attempt)
  end

  defp delivery?(_, _), do: false

  defp handle_configuration?(handle) do
    is_atom(handle.adapter) and not is_nil(handle.adapter) and is_atom(handle.ingress_mode) and
      is_map(handle.connector_attrs) and is_map(handle.sender) and nonempty?(handle.sender[:id])
  end

  defp rooms?(%{direct: direct, shared: shared}), do: nonempty?(direct) and nonempty?(shared)
  defp rooms?(_), do: false

  defp delivery_coordinates?(attempt) do
    positive?(attempt.channel_config_id) and nonempty?(attempt.channel_id) and
      optional_id?(attempt.thread_id) and optional_id?(attempt.message_id)
  end

  defp delivery_content?(attempt) do
    (is_nil(attempt.text) or is_binary(attempt.text)) and is_map(attempt.native_payload)
  end

  defp delivery_outcome?(%{outcome: {:ok, id}, message_id: id}), do: nonempty?(id)
  defp delivery_outcome?(%{outcome: {:error, _}, message_id: nil}), do: true
  defp delivery_outcome?(_), do: false

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp optional_id?(nil), do: true
  defp optional_id?(value), do: nonempty?(value)
  defp supported_or_explained?(true), do: true
  defp supported_or_explained?({:unsupported, reason}), do: nonempty?(reason)
  defp supported_or_explained?(_), do: false
end
