defmodule Zaq.Channels.LinkedDevice.PairingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Zaq.Channels.LinkedDevice.Pairing

  property "only pairing snapshots expose QR material; provider details never escape" do
    check all(
            qr <- string(:alphanumeric, min_length: 1),
            status <-
              member_of([
                :connecting,
                :authenticating,
                :pairing,
                :connected,
                :expired,
                :failed,
                :disconnected,
                :logged_out
              ])
          ) do
      snapshot =
        Pairing.from_notification(%{
          status: status,
          attempt_id: make_ref(),
          qr: qr,
          secret: "never"
        })

      assert snapshot.mode == "linked_device"
      assert snapshot.qr == if(status == :pairing, do: qr, else: nil)
      refute Map.has_key?(snapshot, :secret)
      if status == :expired, do: assert(snapshot.phase == :expired)
      if status == :connected, do: assert(snapshot.phase == :connected)
      if status == :authenticating, do: assert(snapshot.phase == :pending)
    end
  end
end
