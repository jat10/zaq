defmodule Zaq.TestSupport.Channels.Integration.ProviderState do
  @moduledoc """
  Isolated fake-provider request ledger and matched response queues.

  Matching scripts are consumed only by the specified operation and fields.
  Exhausted scripts fail explicitly; incidental status/typing keeps its normal
  provider response. This process stores external observations, never ZAQ records.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec bind(pid(), pos_integer()) :: :ok
  def bind(pid, connector_id), do: GenServer.call(pid, {:bind, connector_id})

  @spec script(pid(), map()) :: :ok | {:error, :invalid_script}
  def script(pid, script), do: GenServer.call(pid, {:script, script})

  @spec attempt(pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def attempt(pid, attrs), do: GenServer.call(pid, {:attempt, attrs})

  @spec deliveries(pid()) :: [map()]
  def deliveries(pid), do: GenServer.call(pid, :deliveries)

  @doc "Stores provider-side message state for real root lookup and edit requests."
  @spec remember(pid(), String.t(), map()) :: :ok
  def remember(pid, id, payload), do: GenServer.call(pid, {:remember, id, payload})

  @spec message(pid(), String.t()) :: map() | nil
  def message(pid, id), do: GenServer.call(pid, {:message, id})

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         owner: opts[:owner],
         provider: opts[:provider],
         scope: opts[:scope],
         connector_id: nil,
         scripts: [],
         deliveries: [],
         sequence: 0,
         messages: %{},
         id_prefix: Keyword.get(opts, :id_prefix, "sent-")
       }}

  @impl true
  def handle_call({:bind, connector}, _from, state),
    do: {:reply, :ok, %{state | connector_id: connector}}

  def handle_call(
        {:script, %{operation: operation, match: match, results: [_ | _]} = script},
        _from,
        state
      )
      when operation in [:send, :edit, :typing] and is_map(match) do
    remaining = Enum.reject(state.scripts, &(&1.operation == operation and &1.match == match))
    {:reply, :ok, %{state | scripts: remaining ++ [script]}}
  end

  def handle_call({:script, _}, _from, state), do: {:reply, {:error, :invalid_script}, state}

  def handle_call({:attempt, attrs}, _from, state) do
    sequence = state.sequence + 1
    id = Map.get(attrs, :message_id) || state.id_prefix <> Integer.to_string(sequence)
    {outcome, scripts} = consume(state.scripts, attrs, {:ok, id})

    message_id =
      case outcome do
        {:ok, id} -> id
        {:error, _} -> nil
      end

    attempt =
      Map.merge(%{thread_id: nil, text: nil}, attrs)
      |> Map.merge(%{
        sequence: sequence,
        provider: state.provider,
        channel_config_id: state.connector_id,
        message_id: message_id,
        outcome: outcome
      })

    send(state.owner, {:channel_provider_attempt, state.scope, attempt})

    {:reply, outcome,
     %{state | scripts: scripts, sequence: sequence, deliveries: [attempt | state.deliveries]}}
  end

  def handle_call(:deliveries, _from, state), do: {:reply, Enum.reverse(state.deliveries), state}

  def handle_call({:remember, id, payload}, _from, state),
    do: {:reply, :ok, %{state | messages: Map.put(state.messages, id, payload)}}

  def handle_call({:message, id}, _from, state), do: {:reply, Map.get(state.messages, id), state}

  defp consume([], _attrs, default), do: {default, []}

  defp consume([script | rest], attrs, default) do
    if script.operation == attrs.operation and
         Map.take(attrs, Map.keys(script.match)) == script.match do
      case script.results do
        [result | results] -> {result, [%{script | results: results} | rest]}
        [] -> {{:error, :script_exhausted}, [script | rest]}
      end
    else
      {result, remaining} = consume(rest, attrs, default)
      {result, [script | remaining]}
    end
  end
end
