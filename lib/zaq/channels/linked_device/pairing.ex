defmodule Zaq.Channels.LinkedDevice.Pairing do
  @moduledoc "Provider-neutral, attempt-scoped pairing presentation state. QR material stays in memory."

  @doc "Projects a normalized adapter lifecycle snapshot into the shared BO contract."
  def from_notification(%{status: status, attempt_id: attempt, qr: qr}) do
    phase =
      case status do
        :connected -> :connected
        :pairing -> :pairing
        :expired -> :expired
        :failed -> :failed
        value when value in [:disconnected, :logged_out] -> :disconnected
        _ -> :pending
      end

    %{
      attempt_id: inspect(attempt),
      phase: phase,
      expires_at: nil,
      qr: if(phase == :pairing and is_binary(qr), do: qr)
    }
    |> presentation()
  end

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
