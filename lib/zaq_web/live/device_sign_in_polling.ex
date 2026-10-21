defmodule ZaqWeb.Live.DeviceSignInPolling do
  @moduledoc """
  One device-sign-in observation timer per LiveView. Reopening the same attempt
  preserves its timer; switching or stopping cancels it. A fresh generation for
  each tick rejects messages already queued before cancellation or consumption.
  Only observation identity lives here, never provider instructions or domain IO.
  """
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn
  alias ZaqWeb.Live.ObservationPolling

  @doc "Observes an in-progress attempt idempotently, or stops observing a terminal/missing attempt."
  def schedule(socket, attempt, event) do
    identity = if is_map(attempt), do: attempt[:attempt_id]

    ObservationPolling.schedule(
      socket,
      :device_sign_in_polling,
      identity,
      event,
      1_000,
      DeviceSignIn.in_progress?(attempt)
    )
  end

  @doc "Consumes exactly one matching tick before its caller fetches status and schedules a successor."
  def consume(socket, id, generation) do
    ObservationPolling.consume(socket, :device_sign_in_polling, id, generation)
  end
end
