defmodule Zaq.Channels.LinkedDeviceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.LinkedDevice

  test "shared configuration does not require a provider-specific module" do
    assert {:ok, ingress} =
             LinkedDevice.ingress(
               %{id: 7, provider: "example"},
               {__MODULE__, []}
             )

    assert ingress.profile == "zaq_linked_device_7"
    assert ingress.config.storage == {__MODULE__, []}
  end

  test "runtime binding defeats persisted profile, storage and history overrides" do
    config = %{
      id: 42,
      provider: "whatsapp",
      settings: %{
        "jido_chat" => %{
          "ingress" => %{
            "profile" => "another_account",
            "storage_root" => "/tmp/untrusted",
            "config" => %{"sync_history" => true, "sync_full_history" => true}
          }
        }
      }
    }

    storage = {__MODULE__, credential_id: 123}
    assert {:ok, ingress} = LinkedDevice.ingress(config, storage)
    assert ingress.mode == :linked_device
    assert ingress.profile == "zaq_linked_device_42"
    assert ingress.config.storage == storage
    refute ingress.config.sync_history
    refute ingress.config.sync_full_history
    refute Map.has_key?(ingress, :storage_root)

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("connector_42",
               ingress: ingress,
               sink_mfa: {__MODULE__, :receive_payload, []}
             )

    {_module, :start_link, [worker_opts]} = spec.start
    assert worker_opts[:config] == ingress.config
  end

  test "rejects missing identities, mismatched providers and implicit file storage" do
    assert {:error, :invalid_connector} = LinkedDevice.profile(%{id: nil})
    assert {:error, :invalid_connector} = LinkedDevice.profile(%{id: "42"})
    assert {:error, :invalid_storage} = LinkedDevice.ingress(%{id: 42}, nil)
  end

  property "distinct persisted connectors always receive distinct stable profiles" do
    check all(first <- positive_integer(), offset <- positive_integer()) do
      second = first + offset
      assert {:ok, first_profile} = LinkedDevice.profile(%{id: first})
      assert {:ok, second_profile} = LinkedDevice.profile(%{id: second})
      refute first_profile == second_profile
      assert {:ok, ^first_profile} = LinkedDevice.profile(%{id: first, name: "Renamed"})
    end
  end
end
