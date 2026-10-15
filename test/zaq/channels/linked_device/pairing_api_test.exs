defmodule Zaq.Channels.LinkedDevice.PairingApiTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Zaq.Channels.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event

  defmodule ExampleAdapter do
    @moduledoc false
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :example

    @impl true
    def transform_incoming(_), do: {:error, :unsupported}

    @impl true
    def send_message(_, _, _), do: {:error, :unsupported}

    @impl true
    def authenticate(request, owner_id, opts) do
      {:ok,
       %{
         phase: :pending,
         session: request[:session] || self(),
         owner_id: owner_id,
         request: request,
         callbacks: Keyword.take(opts, [:persist_mfa, :start_mfa, :sink_mfa])
       }}
    end
  end

  defmodule ExampleConfig do
    @moduledoc false
    def get(:zaq, :channels, _default, opts),
      do: %{example: %{bridge: Zaq.Channels.JidoChatBridge, adapter: opts[:test_adapter]}}
  end

  defmodule FailingRuntime do
    @moduledoc false
    def bridge_for(_), do: __MODULE__
    defdelegate fetch_channel_config(provider, id), to: Zaq.Channels.Bridge
    def sync_provider_runtime(_), do: {:error, :connection_start_failed}
  end

  test "retry propagates the actual runtime failure" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})

    event =
      Event.new(%{provider: :whatsapp, channel_config_id: config.id}, :channels,
        actor: %{user_id: admin.id},
        opts: [confidential: true, bridge_module: FailingRuntime]
      )

    assert Api.handle_event(event, :channel_retry_linked_device, nil).response ==
             {:error, :connection_start_failed}
  end

  test "a second adapter traverses the authorized Action and both bridges" do
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}
    adapter = ExampleAdapter

    begin_request = %{provider: :example, op: :begin, owner: self()}
    assert {:ok, first} = authenticate(begin_request, actor, adapter)
    assert first.owner_id == {"example", admin.id}
    assert first.request == begin_request

    assert {Zaq.Channels.JidoChatBridge, :persist_authentication, [:example]} =
             first.callbacks[:persist_mfa]

    assert {Zaq.Channels.JidoChatBridge, :from_listener, [%{provider: :example}, capability]} =
             first.callbacks[:sink_mfa]

    assert is_reference(capability)

    assert {:ok, followup} =
             authenticate(
               %{
                 provider: :example,
                 op: :confirm,
                 session: first.session,
                 account_id: "account-7"
               },
               actor,
               adapter
             )

    assert followup.owner_id == first.owner_id
    assert followup.request.account_id == "account-7"
    assert followup.callbacks == []

    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    assert {:error, %{details: %{reason: :unauthorized}}} =
             authenticate(
               %{provider: :example, op: :status, session: first.session},
               actor,
               adapter
             )
  end

  test "a legacy adapter reports unsupported through the same Action" do
    admin = super_admin_fixture(%{must_change_password: false})
    adapter = Jido.Chat.Telegram.Adapter

    assert {:error, :unsupported} =
             authenticate(
               %{provider: :example, op: :begin, owner: self()},
               %{user_id: admin.id},
               adapter
             )
  end

  test "pairing status and retry deny nil, unprivileged and non-confidential callers" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    user = user_fixture()

    for action <- [:channel_ingress_status, :channel_retry_linked_device],
        {actor, confidential} <- [
          {nil, true},
          {%{user_id: user.id}, true},
          {%{user_id: admin.id}, false}
        ] do
      assert {:error, :unauthorized} = call(config, action, actor, confidential)
    end
  end

  test "authorized status uses exact enabled connector and never trusts a supplied config" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})

    assert {:ok, %{phase: :disconnected, qr: nil}} =
             call(config, :channel_ingress_status, %{user_id: admin.id}, true)

    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:error, _} = call(config, :channel_ingress_status, %{user_id: admin.id}, true)
    assert {:error, _} = call(config, :channel_retry_linked_device, %{user_id: admin.id}, true)
  end

  test "status and retry revalidate an operator whose password must now change" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}

    assert {:ok, _} = call(config, :channel_ingress_status, actor, true)
    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    for action <- [:channel_ingress_status, :channel_retry_linked_device] do
      assert {:error, :unauthorized} = call(config, action, actor, true)
    end
  end

  defp call(config, action, actor, confidential) do
    Event.new(
      %{
        provider: :whatsapp,
        channel_config_id: config.id,
        config: %{config | provider: "telegram"}
      },
      :channels,
      actor: actor,
      opts: [action: action, confidential: confidential]
    )
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp authenticate(request, actor, adapter) do
    Event.new(request, :channels,
      actor: actor,
      opts: [
        action: :pair_linked_device,
        confidential: true,
        config: ExampleConfig,
        test_adapter: adapter
      ]
    )
    |> Api.handle_event(:pair_linked_device, nil)
    |> Map.fetch!(:response)
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{name: "Pairing", provider: "whatsapp", kind: "retrieval"})
    |> Repo.insert!()
  end
end
