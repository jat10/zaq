defmodule Zaq.Channels.LinkedDevice.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.LinkedDevice.{Config, WhatsApp}

  test "shared configuration does not impose WhatsApp options on other providers" do
    assert {:ok, ingress} =
             Config.ingress(
               %{id: 7, provider: "example"},
               Zaq.TestSupport.LinkedDeviceProviderStub,
               {__MODULE__, []}
             )

    assert ingress.config.pairing_method == :code
    refute Map.has_key?(ingress.config, :sync_history)
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
    assert {:ok, ingress} = Config.ingress(config, WhatsApp, storage)
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
    assert {:error, :invalid_connector} = Config.profile(%{id: nil})
    assert {:error, :invalid_connector} = Config.profile(%{id: "42"})
    assert {:error, :invalid_storage} = Config.ingress(%{id: 42}, WhatsApp, nil)

    assert {:error, :provider_mismatch} =
             Config.ingress(%{id: 42, provider: "telegram"}, WhatsApp, {__MODULE__, []})
  end

  property "distinct persisted connectors always receive distinct stable profiles" do
    check all(first <- positive_integer(), offset <- positive_integer()) do
      second = first + offset
      assert {:ok, first_profile} = Config.profile(%{id: first})
      assert {:ok, second_profile} = Config.profile(%{id: second})
      refute first_profile == second_profile
      assert {:ok, ^first_profile} = Config.profile(%{id: first, name: "Renamed"})
    end
  end
end
