defmodule ZaqWeb.Live.ObservationPollingTest do
  use ExUnit.Case, async: true
  alias ZaqWeb.Live.ObservationPolling

  test "observation slots preserve their own interval and stop independently" do
    socket = %Phoenix.LiveView.Socket{}
    socket = ObservationPolling.schedule(socket, :first, :account, :poll, 2_000, true)
    socket = ObservationPolling.schedule(socket, :second, :attempt, :device_status, 1_000, true)
    first = socket.private.first
    second = socket.private.second
    assert first.interval_ms == 2_000
    assert second.interval_ms == 1_000

    reopened = ObservationPolling.schedule(socket, :first, :account, :poll, 2_000, true)
    assert reopened.private.first == first
    stopped = ObservationPolling.stop(reopened, :first)
    assert Process.read_timer(first.timer_ref) == false
    assert stopped.private.second == second
    assert :stale = ObservationPolling.consume(stopped, :first, :account, first.generation)
    ObservationPolling.stop(stopped, :second)
  end
end
