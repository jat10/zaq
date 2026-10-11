defmodule Zaq.Channels.LinkedDevice.PairingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Zaq.Channels.LinkedDevice.{Pairing, WhatsApp}

  test "QR expires at its deadline and successful connection clears it" do
    state =
      Pairing.new("attempt") |> Pairing.apply_event("attempt", {:qr, "secret-qr", 100}, 1000)

    assert Pairing.expire(state, 1099).qr == "secret-qr"
    expired = Pairing.expire(state, 1100)
    assert expired.phase == :expired
    assert expired.qr == nil
    connected = Pairing.apply_event(state, "attempt", :connected, 1050)
    assert Pairing.presentation(connected).status == :ok
    assert connected.qr == nil
  end

  property "stale attempts cannot replace state or introduce QR material" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      current = Pairing.new(id)
      assert Pairing.apply_event(current, id <> "old", {:qr, "old-qr", 60_000}, 0) == current
    end
  end

  test "shared contract accepts another provider and does not expose raw failure details" do
    state =
      Pairing.new("generic")
      |> Pairing.apply_event("generic", {:qr, "another-provider-code", 500}, 0)

    assert Pairing.presentation(state).mode == "linked_device"
    assert Pairing.apply_event(state, "generic", :failed, 1).qr == nil
    refute Map.has_key?(Pairing.presentation(state), :qr_count)
  end

  test "WhatsApp only reports connected after socket open, with bounded QR lifetimes" do
    state = Pairing.new("attempt")

    assert WhatsApp.pairing_event({:amarula, :connection_update, %{qr: "qr"}}, state) ==
             {:qr, "qr", 60_000}

    assert WhatsApp.pairing_event({:amarula, :connection_update, %{qr: "qr"}}, %{
             state
             | qr_count: 1
           }) == {:qr, "qr", 20_000}

    assert WhatsApp.pairing_event({:amarula, :pairing_success, %{}}, state) == :pending

    assert WhatsApp.pairing_event({:amarula, :connection_update, %{connection: :open}}, state) ==
             :connected

    assert WhatsApp.pairing_event({:amarula, :error, %{secret: "redacted"}}, state) == :failed
  end
end
