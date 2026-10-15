defmodule Zaq.Channels.JidoChatBridge.SavedConnectionTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.Request
  alias Jido.Chat.WhatsApp.Storage.Split
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.ChannelConfig

  test "saved ingress uses the adapter's stable binding and ignores connector overrides" do
    config = connector()

    config = %{
      config
      | settings: %{
          "jido_chat" => %{
            "ingress" => %{
              "profile" => "another_account",
              "storage_root" => "/tmp/untrusted",
              "config" => %{"sync_history" => true, "sync_full_history" => true}
            }
          }
        }
    }

    assert {:ok, ingress} = JidoChatBridge.saved_connection_options(config, Adapter)
    assert ingress.mode == :linked_device
    assert {:ok, ingress.profile} == JidoChatBridge.connection_profile(config)
    assert {Split, storage_opts} = ingress.storage
    assert storage_opts[:context].channel_config_id == config.id
    refute ingress.sync_history
    refute ingress.sync_full_history
    refute Map.has_key?(ingress, :storage_root)

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("connector_#{config.id}",
               ingress: ingress,
               sink_mfa: {__MODULE__, :receive_payload, []}
             )

    {_module, :start_link, [worker_opts]} = spec.start
    assert worker_opts[:config].profile == ingress.profile
    assert worker_opts[:config].storage == ingress.storage
  end

  test "invalid and disabled connectors cannot yield saved options" do
    assert {:error, :invalid_connector} = JidoChatBridge.connection_profile(%{id: nil})

    assert {:error, :invalid_connector} =
             JidoChatBridge.saved_connection_options(%{id: "42"}, Adapter)

    assert {:error, :unsupported} = JidoChatBridge.saved_connection_options(%{id: 42}, __MODULE__)

    config = connector()
    assert {:ok, _} = JidoChatBridge.saved_connection_options(config, Adapter)
    Repo.update!(Ecto.Changeset.change(config, enabled: false))

    assert {:error, :connector_unavailable} =
             JidoChatBridge.saved_connection_options(config, Adapter)
  end

  property "different durable bindings yield distinct stable adapter profiles" do
    check all(first <- positive_integer(), offset <- positive_integer()) do
      second = first + offset
      first_binding = %{channel_config_id: first, credential_id: 1}
      second_binding = %{channel_config_id: second, credential_id: 1}
      opts = [context: :runtime, sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})]
      first_profile = Adapter.connection_options(first_binding, opts).profile
      second_profile = Adapter.connection_options(second_binding, opts).profile

      refute first_profile == second_profile
      assert first_profile == Adapter.connection_options(first_binding, opts).profile
    end
  end

  test "storage requests bypass listener registration and public chat ingress rejects them" do
    config = connector()
    {_, _, [context, _]} = JidoChatBridge.storage_sink(Map.put(config, :token, "private-token"))
    assert context == %{id: config.id, provider: config.provider}
    event = %Request{binding: nil, request: %{op: :bind}}
    assert {:error, :invalid_storage_request} = JidoChatBridge.from_listener(config, event, [])

    assert {:error, :invalid_storage_request} =
             JidoChatBridge.from_listener(config, nil, event, [])

    {module, function, args} = JidoChatBridge.storage_sink(config)
    assert {:ok, binding} = apply(module, function, args ++ [event, [bridge_id: "absent_bridge"]])
    assert binding.channel_config_id == config.id
    assert {:ok, options} = Adapter.prepare_connection(sink_mfa: {module, function, args})
    {Split, opts} = options.storage
    state = Split.new(opts)
    assert :ok = Split.put(state, options.profile, :creds, :self, %{paired: true})
    assert {:ok, %{paired: true}} = Split.get(state, options.profile, :creds, :self)
  end

  test "trusted sinks reject another connector's binding and another provider" do
    first = connector()
    second = connector()
    sink = JidoChatBridge.storage_sink(first)
    assert {:ok, binding} = Request.call(sink, nil, %{op: :bind})

    assert {:error, :invalid_binding} =
             Request.call(JidoChatBridge.storage_sink(second), binding, %{
               op: :list_keys,
               namespace: "creds"
             })

    assert {:error, :invalid_provider} =
             Request.call(JidoChatBridge.storage_sink(%{provider: "telegram"}), binding, %{
               op: :list_keys,
               namespace: "creds"
             })
  end

  test "a storage callback completes while the bridge State itself is handling work" do
    config = connector()
    assert {:ok, options} = JidoChatBridge.saved_connection_options(config, Adapter)
    {Split, opts} = options.storage
    storage = Split.new(opts)

    pid =
      start_supervised!(
        {State,
         bridge_id: "storage_reentry_#{config.id}",
         config: ChannelConfig.to_runtime_config(config),
         provider: :whatsapp}
      )

    Sandbox.allow(Repo, self(), pid)

    # Run on the real State process, as an outbound adapter operation does.
    # Routing the storage request back through State would wait on itself.
    :sys.replace_state(pid, fn current ->
      assert :ok = Split.put(storage, options.profile, :creds, :self, %{paired: true})
      current
    end)

    assert {:ok, %{paired: true}} = Split.get(storage, options.profile, :creds, :self)
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: Ecto.UUID.generate(),
      provider: "whatsapp",
      kind: "retrieval"
    })
    |> Repo.insert!()
  end
end
