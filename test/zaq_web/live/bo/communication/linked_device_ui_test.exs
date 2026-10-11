defmodule ZaqWeb.Live.BO.Communication.LinkedDeviceUITest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.LinkedDevicePairing
  alias ZaqWeb.Live.BO.Communication.LinkedDeviceUI

  test "stale result and timer cannot update another selected connector" do
    socket = socket()
    assert LinkedDeviceUI.result(socket, make_ref(), {:ok, {:ok, %{qr: "wrong"}}}) == socket
    assert LinkedDeviceUI.refresh(socket, make_ref()) == socket
    assert socket.assigns.linked_device_modal.config_id == 2
  end

  test "closing cancels polling and clears QR material" do
    socket = socket()
    timer = Process.send_after(self(), :should_not_arrive, 5000)
    socket = Phoenix.Component.assign(socket, :linked_device_timer, timer)
    closed = LinkedDeviceUI.close(socket)
    assert closed.assigns.linked_device_modal == nil
    assert Process.read_timer(timer) == false

    assert LinkedDeviceUI.result(
             closed,
             socket.assigns.linked_device_modal.generation,
             {:ok, {:ok, %{qr: "late"}}}
           ) == closed
  end

  test "retry failure clears QR and polling is bounded" do
    socket = socket()
    generation = socket.assigns.linked_device_modal.generation
    failed = LinkedDeviceUI.result(socket, generation, {:ok, {:error, :restart_failed}})
    assert failed.assigns.linked_device_modal.status.phase == :failed
    refute Map.has_key?(failed.assigns.linked_device_modal.status, :qr)
    modal = %{socket.assigns.linked_device_modal | attempts: 89}
    socket = Phoenix.Component.assign(socket, :linked_device_modal, modal)

    expired =
      LinkedDeviceUI.result(socket, generation, {:ok, {:ok, %{phase: :pairing, qr: "old"}}})

    assert expired.assigns.linked_device_modal.status.phase == :expired
    assert expired.assigns.linked_device_timer == nil
  end

  test "QR rendering draws modules without reflecting raw content or exposing expired QR" do
    html =
      render_component(&LinkedDevicePairing.modal/1,
        name: "Second account",
        provider: "Example",
        status: %{phase: :pairing, qr: "<script>secret</script>", summary: "Scan"}
      )

    assert html =~ "Device connection QR code"
    refute html =~ "<script>"
    refute html =~ "secret"

    expired =
      render_component(&LinkedDevicePairing.modal/1,
        name: "Second account",
        provider: "Example",
        status: %{phase: :expired, qr: "old", summary: "Expired"},
        history_disabled: true
      )

    refute expired =~ "Device connection QR code"
    assert expired =~ "Retry connection"
    assert expired =~ "History sync is disabled"
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        linked_device_timer: nil,
        linked_device_modal: %{
          config_id: 2,
          name: "Second",
          generation: make_ref(),
          attempts: 0,
          status: %{qr: "current"}
        }
      }
    }
  end
end
