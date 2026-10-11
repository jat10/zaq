defmodule Zaq.Channels.LinkedDevice.Pairing do
  @moduledoc "Provider-neutral, attempt-scoped pairing presentation state. QR material stays in memory."

  @doc "Starts a fresh attempt. A new owner always creates a new generation."
  def new(attempt_id),
    do: %{attempt_id: attempt_id, phase: :pending, qr: nil, expires_at: nil, qr_count: 0}

  @doc "Applies only events belonging to this attempt; unknown events preserve state."
  def apply_event(state, attempt_id, event, now)

  def apply_event(%{attempt_id: expected} = state, attempt_id, _event, _now)
      when expected != attempt_id, do: state

  def apply_event(state, _attempt, {:qr, qr, ttl}, now)
      when is_binary(qr) and is_integer(ttl) and ttl > 0 do
    %{state | phase: :pairing, qr: qr, expires_at: now + ttl, qr_count: state.qr_count + 1}
  end

  def apply_event(state, _attempt, phase, _now)
      when phase in [:pending, :connected, :disconnected, :expired, :failed],
      do: %{state | phase: phase, qr: nil, expires_at: nil}

  def apply_event(state, _, _, _), do: state

  @doc "Clears expired QR material before returning bounded presentation data."
  def expire(%{expires_at: expires} = state, now) when is_integer(expires) and expires <= now,
    do: %{state | phase: :expired, qr: nil, expires_at: nil}

  def expire(state, _), do: state

  @doc "Returns generic ingress status without provider credentials or error payloads."
  def presentation(state) do
    {status, summary} =
      case state.phase do
        :connected -> {:ok, "Linked device connected"}
        :pairing -> {:pending, "Scan the QR code to connect"}
        :pending -> {:pending, "Waiting for device connection"}
        :expired -> {:error, "Pairing code expired; retry connection"}
        :disconnected -> {:error, "Linked device disconnected"}
        :failed -> {:error, "Device connection failed; retry connection"}
      end

    state
    |> Map.take([:attempt_id, :phase, :qr, :expires_at])
    |> Map.merge(%{status: status, summary: summary, mode: "linked_device"})
  end
end
