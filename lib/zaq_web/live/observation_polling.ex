defmodule ZaqWeb.Live.ObservationPolling do
  @moduledoc """
  Socket-local observation timers with one consumable token per scheduled tick.

  Callers supply observation identity, activity and interval. Domain state and
  async-result generations remain with the caller. Each slot stores private
  metadata and exposes its timer reference as an assign for lifecycle cleanup.
  """
  alias Phoenix.LiveView

  @doc "Observes an active identity idempotently; changing identity or stopping cancels its timer."
  @spec schedule(LiveView.Socket.t(), atom(), term(), atom(), pos_integer(), boolean()) ::
          LiveView.Socket.t()
  def schedule(socket, key, identity, event, interval_ms, active?) do
    if active? do
      case socket.private[key] do
        %{identity: ^identity, event: ^event, interval_ms: ^interval_ms} -> socket
        _ -> start_timer(stop(socket, key), key, identity, event, interval_ms)
      end
    else
      stop(socket, key)
    end
  end

  @doc "Consumes exactly one current tick, rejecting duplicates and queued stale messages."
  @spec consume(LiveView.Socket.t(), atom(), term(), reference()) ::
          {:ok, LiveView.Socket.t()} | :stale
  def consume(socket, key, identity, generation) do
    case socket.private[key] do
      %{identity: ^identity, generation: ^generation} -> {:ok, stop(socket, key)}
      _ -> :stale
    end
  end

  @doc "Cancels a slot and clears both its observation metadata and timer assign."
  @spec stop(LiveView.Socket.t(), atom()) :: LiveView.Socket.t()
  def stop(socket, key) do
    timer = socket.private[key]
    reference = if timer, do: timer.timer_ref, else: socket.assigns[key]
    if is_reference(reference), do: Process.cancel_timer(reference)

    socket
    |> LiveView.put_private(key, nil)
    |> Phoenix.Component.assign(key, nil)
  end

  defp start_timer(socket, key, identity, event, interval_ms) do
    generation = make_ref()
    timer = Process.send_after(self(), {event, identity, generation}, interval_ms)

    socket
    |> LiveView.put_private(key, %{
      identity: identity,
      generation: generation,
      timer_ref: timer,
      event: event,
      interval_ms: interval_ms
    })
    |> Phoenix.Component.assign(key, timer)
  end
end
