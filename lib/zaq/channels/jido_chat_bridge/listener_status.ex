defmodule Zaq.Channels.JidoChatBridge.ListenerStatus do
  @moduledoc false

  @auth_timeout 250

  def auth_status(pid, timeout \\ @auth_timeout) when is_pid(pid) do
    ref = make_ref()
    monitor_ref = Process.monitor(pid)

    send(pid, {:auth_status, self(), ref})

    receive do
      {^ref, status} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, status}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  def status_from_auth(:ok) do
    %{status: :ok, summary: "Ingress listener authenticated"}
  end

  def status_from_auth(status) when status in [:pending, :unknown] do
    %{status: :pending, summary: "Ingress listener is connecting and authenticating"}
  end

  def status_from_auth({:error, :timeout}) do
    %{status: :pending, summary: "Ingress listener authentication status is pending"}
  end

  def status_from_auth({:error, reason}), do: from_exit_reason(reason)

  def status_from_auth(_status) do
    %{status: :pending, summary: "Ingress listener authentication status is unknown"}
  end

  @doc """
  Projects a normalized linked-device lifecycle snapshot into the shared BO contract.

  Only pairing snapshots expose QR material. Provider credentials and error
  payloads are excluded from the returned status.
  """
  @spec from_lifecycle(map()) :: map()
  def from_lifecycle(%{status: status, attempt_id: attempt, qr: qr}) do
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
    |> lifecycle_presentation()
  end

  def from_exit_reason(:normal), do: nil
  def from_exit_reason(:shutdown), do: nil
  def from_exit_reason({:shutdown, _reason}), do: nil

  def from_exit_reason({:auth_failed, reason}) do
    %{
      status: :error,
      summary: "Ingress listener authentication failed",
      reason: reason
    }
  end

  def from_exit_reason({:transport_failed, reason}) do
    %{
      status: :error,
      summary: "Ingress listener connection failed",
      reason: reason
    }
  end

  def from_exit_reason(reason) do
    %{
      status: :error,
      summary: "Ingress listener stopped",
      reason: reason
    }
  end

  def query_listener_pids(listener_pids) when is_list(listener_pids) do
    listener_pids
    |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
    |> Enum.map(&auth_status/1)
    |> status_from_auth_results()
  end

  defp lifecycle_presentation(state) do
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

  defp status_from_auth_results([]), do: nil

  defp status_from_auth_results(results) do
    cond do
      Enum.any?(results, &(&1 == {:ok, :ok})) ->
        status_from_auth(:ok)

      error = Enum.find(results, &match?({:error, reason} when reason != :timeout, &1)) ->
        status_from_auth(error)

      true ->
        %{status: :pending, summary: "Ingress listener is connecting and authenticating"}
    end
  end
end
