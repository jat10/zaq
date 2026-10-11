defmodule Zaq.Engine.Connect.LinkedDeviceStorageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.LinkedDevice.Config
  alias Zaq.Channels.LinkedDevice.WhatsAppStorage
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect.LinkedDeviceStorage
  alias Zaq.Event

  test "encrypted state survives a new adapter context and remains connector isolated" do
    first = connector("First")
    second = connector("Second")
    assert {:ok, first_binding} = LinkedDeviceStorage.bind(first.id)
    assert {:ok, second_binding} = LinkedDeviceStorage.bind(second.id)
    refute first_binding.credential_id == second_binding.credential_id
    assert {:ok, ^first_binding} = LinkedDeviceStorage.bind(first.id)

    state = WhatsAppStorage.new(binding: first_binding)
    value = %{private_key: <<0, 255, 127>>, session: {123, :paired}}
    assert :ok = WhatsAppStorage.put(state, first_binding.profile, :creds, :self, value)

    [[encrypted]] = Repo.query!("SELECT encrypted_value FROM connect_linked_device_states").rows
    assert String.starts_with?(encrypted, "enc:")
    refute String.contains?(encrypted, "private_key")

    restored = WhatsAppStorage.new(binding: first_binding)
    assert {:ok, ^value} = WhatsAppStorage.get(restored, first_binding.profile, :creds, :self)
    other = WhatsAppStorage.new(binding: second_binding)
    assert :error = WhatsAppStorage.get(other, second_binding.profile, :creds, :self)

    assert_raise ArgumentError, fn ->
      WhatsAppStorage.get(state, second_binding.profile, :creds, :self)
    end

    assert {:ok, [:self]} = WhatsAppStorage.list_keys(state, first_binding.profile, :creds)
    assert :ok = WhatsAppStorage.delete(state, first_binding.profile, :creds, :self)
    assert :error = WhatsAppStorage.get(state, first_binding.profile, :creds, :self)
  end

  test "storage event requires confidential synchronous privileged runtime context" do
    config = connector("Protected")
    request = %{op: :bind, channel_config_id: config.id}

    for opts <- [[], [confidential: true], [linked_device_runtime: true]] do
      event = Event.new(request, :engine, name: :linked_device_storage, opts: opts)

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :linked_device_storage, %{})
    end

    event =
      Event.new(request, :engine,
        name: :linked_device_storage,
        type: :async,
        opts: [confidential: true, linked_device_runtime: true]
      )

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :linked_device_storage, %{})
  end

  test "disabled connectors cannot read or write and disabling preserves state" do
    config = connector("Disabled")
    assert {:ok, binding} = LinkedDeviceStorage.bind(config.id)
    assert {:ok, profile} = Config.profile(config)
    state = WhatsAppStorage.new(binding: binding)
    assert :ok = WhatsAppStorage.put(state, profile, :session, "peer", %{v: 1})
    disabled = config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    assert {:error, :connector_unavailable} =
             WhatsAppStorage.put(state, profile, :session, "peer", %{v: 2})

    disabled |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    assert {:ok, %{v: 1}} = WhatsAppStorage.get(state, profile, :session, "peer")
    assert :ok = WhatsAppStorage.clear(state, profile)
    assert :error = WhatsAppStorage.get(state, profile, :session, "peer")
  end

  test "forged credential association and corrupt stored ciphertext fail closed" do
    first = connector("Bound")
    second = connector("Other")
    assert {:ok, binding} = LinkedDeviceStorage.bind(first.id)
    assert {:ok, other} = LinkedDeviceStorage.bind(second.id)
    forged = %{binding | credential_id: other.credential_id}

    assert {:error, :invalid_binding} =
             LinkedDeviceStorage.dispatch(%{op: :clear, binding: forged})

    state = WhatsAppStorage.new(binding: binding)
    assert :ok = WhatsAppStorage.put(state, binding.profile, :creds, :self, %{key: "secret"})
    Repo.query!("UPDATE connect_linked_device_states SET encrypted_value = 'plaintext'")

    assert_raise RuntimeError, "Linked-device storage read failed", fn ->
      WhatsAppStorage.get(state, binding.profile, :creds, :self)
    end
  end

  test "concurrent updates preserve separate protocol records and support replacement" do
    config = connector("Concurrent")
    assert {:ok, binding} = LinkedDeviceStorage.bind(config.id)
    state = WhatsAppStorage.new(binding: binding)

    results =
      Task.async_stream(1..8, fn n ->
        WhatsAppStorage.put(state, binding.profile, :session, "peer_#{n}", %{version: n})
      end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, keys} = WhatsAppStorage.list_keys(state, binding.profile, :session)
    assert length(keys) == 8
    assert :ok = WhatsAppStorage.put(state, binding.profile, :session, "peer_1", %{version: 9})
    assert {:ok, %{version: 9}} = WhatsAppStorage.get(state, binding.profile, :session, "peer_1")
  end

  defp connector(name) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{name: name, provider: "whatsapp", kind: "retrieval"})
    |> Repo.insert!()
  end
end
