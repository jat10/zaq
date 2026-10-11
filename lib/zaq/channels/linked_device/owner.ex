defmodule Zaq.Channels.LinkedDevice.Owner do
  @moduledoc """
  Owns one linked-device connection independently of its adapter event decoder.

  The provider sends events here; attaching a replacement decoder does not create
  another connection. A global name prevents duplicate owners on connected ZAQ
  nodes. Provider connect must safely adopt a connection left by an untrappable
  owner kill. Normal shutdown stops the provider connection and retains credentials.
  """
  use GenServer

  alias Zaq.Channels.LinkedDevice.Pairing

  @doc "Reads the selected owner's pairing state without contacting its decoder."
  def status(profile) do
    GenServer.call(name(profile), :pairing_status)
  catch
    :exit, _ ->
      {:ok, Pairing.new(nil) |> Map.put(:phase, :disconnected) |> Pairing.presentation()}
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name(opts[:config].profile))
  end

  @doc "Attaches a decoder process to the exact connection owner."
  @spec attach(String.t(), pid()) :: {:ok, term()} | {:error, term()}
  def attach(profile, pid), do: GenServer.call(name(profile), {:attach, pid})

  @doc false
  def name(profile), do: {:global, {__MODULE__, profile}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    provider = Keyword.fetch!(opts, :provider)
    config = Keyword.fetch!(opts, :config)

    case provider.connect(config, self()) do
      {:ok, conn} ->
        {:ok,
         %{
           provider: provider,
           config: config,
           conn: conn,
           pairing: Pairing.new(Ecto.UUID.generate()),
           decoder: nil,
           monitor: nil,
           pending: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:pairing_status, _from, state) do
    pairing = Pairing.expire(state.pairing, System.system_time(:millisecond))
    {:reply, {:ok, Pairing.presentation(pairing)}, %{state | pairing: pairing}}
  end

  def handle_call({:attach, pid}, _from, state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    Enum.each(Enum.reverse(state.pending), &send(pid, &1))

    {:reply, {:ok, state.conn},
     %{state | decoder: pid, monitor: Process.monitor(pid), pending: []}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, %{state | decoder: nil, monitor: nil}}

  def handle_info(message, state) do
    pairing =
      if function_exported?(state.provider, :pairing_event, 2) do
        event = state.provider.pairing_event(message, state.pairing)

        Pairing.apply_event(
          state.pairing,
          state.pairing.attempt_id,
          event,
          System.system_time(:millisecond)
        )
      else
        state.pairing
      end

    state = %{state | pairing: pairing}

    if function_exported?(state.provider, :forward_event?, 1) and
         not state.provider.forward_event?(message),
       do: {:noreply, state},
       else: forward(message, state)
  end

  defp forward(message, %{decoder: nil, pending: pending} = state) do
    if length(pending) < 100,
      do: {:noreply, %{state | pending: [message | pending]}},
      else: {:stop, :decoder_unavailable, state}
  end

  defp forward(message, state) do
    send(state.decoder, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: state.provider.stop(state.config)
end
