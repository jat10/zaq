defmodule Zaq.Channels.LinkedDevice.RestartTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  test "fresh connection processes restore two accounts and disabling one preserves the other" do
    previous = Application.fetch_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaq, :channels, value)
        :error -> Application.delete_env(:zaq, :channels)
      end
    end)

    start_supervised!({Transport, observer: self()})
    first = connector()
    second = connector()

    on_exit(fn ->
      JidoChatBridge.stop_runtime(first)
      JidoChatBridge.stop_runtime(second)
    end)

    for config <- [first, second] do
      assert :ok = JidoChatBridge.start_runtime(config)
      assert_receive {:whatsapp_connected_config, options}
      assert options.profile == profile(config)
      refute options.sync_history
      refute options.sync_full_history
      assert phase(config, :pairing)
      {:ok, %{qr: qr}} = JidoChatBridge.channel_ingress_status(config)
      assert :ok = Transport.scan(profile(config), qr)
      assert phase(config, :connected)
    end

    {:ok, first_conn} = Transport.resolve_conn(profile: profile(first))
    {:ok, second_conn} = Transport.resolve_conn(profile: profile(second))
    assert :ok = JidoChatBridge.stop_runtime(first)
    assert :ok = JidoChatBridge.stop_runtime(second)
    refute Process.alive?(first_conn)
    refute Process.alive?(second_conn)
    stop_supervised(Transport)
    start_supervised!({Transport, observer: self()})
    assert Transport.mailbox() == %{}
    disabled_config = connector() |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    {:ok, archived_config} = ChannelConfig.archive(connector())

    assert :ok =
             Supervisor.terminate_child(
               Zaq.Channels.Supervisor,
               Zaq.Channels.BridgeSupervisor
             )

    assert {:ok, _} =
             Supervisor.restart_child(
               Zaq.Channels.Supervisor,
               Zaq.Channels.BridgeSupervisor
             )

    for config <- [first, second] do
      assert_receive {:whatsapp_connected_config, options}
      refute options.sync_history
      refute options.sync_full_history
      assert phase(config, :connected)
      assert {:ok, %{qr: nil}} = JidoChatBridge.channel_ingress_status(config)
    end

    assert {:error, :not_connected} = Transport.resolve_conn(profile: profile(disabled_config))
    assert {:error, :not_connected} = Transport.resolve_conn(profile: profile(archived_config))

    disabled = first |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert :ok = JidoChatBridge.sync_runtime(first, disabled)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: profile(first))
    assert {:ok, remaining} = Transport.resolve_conn(profile: profile(second))
    assert Process.alive?(remaining)
    enabled = disabled |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    assert :ok = JidoChatBridge.sync_runtime(disabled, enabled)
    assert phase(enabled, :connected)
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

  defp profile(config), do: "zaq_linked_device_#{config.id}"

  defp phase(config, expected, attempts \\ 100)
  defp phase(_, _, 0), do: false

  defp phase(config, expected, attempts) do
    case JidoChatBridge.channel_ingress_status(config) do
      {:ok, %{phase: ^expected}} ->
        true

      _ ->
        Process.sleep(5)
        phase(config, expected, attempts - 1)
    end
  end
end
