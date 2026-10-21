defmodule Zaq.TestSupport.Channels.Integration.Drivers.WhatsApp do
  @moduledoc """
  Native linked-device messages through real pairing and the existing fake service.

  WhatsAppFlowAdapter only injects WhatsAppFlowTransport. Saved connector lookup,
  Amarula storage, listener normalization and outbound adapter operations remain
  real. The singleton service requires synchronous tests; ledgers are profile scoped.
  This seam covers consumer messages, not WhatsApp's encrypted network protocol.
  """
  @behaviour Zaq.TestSupport.Channels.Integration.Driver

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.TestSupport.Channels.Integration.ProviderState
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  @self_jid "15550001@s.whatsapp.net"

  @impl true
  def start(opts) do
    scope = Keyword.fetch!(opts, :scope)
    owner = Keyword.fetch!(opts, :owner_pid)
    unless Process.whereis(Transport), do: start_supervised!({Transport, observer: owner})

    ledger =
      start_supervised!(
        Supervisor.child_spec(
          {ProviderState, provider: :whatsapp, owner: owner, scope: scope},
          id: {__MODULE__, scope}
        )
      )

    peer = "1556#{System.unique_integer([:positive, :monotonic])}@s.whatsapp.net"

    {:ok,
     %{
       provider: :whatsapp,
       adapter: WhatsAppFlowAdapter,
       ingress_mode: :linked_device,
       connector_attrs: %{},
       sender: %{id: peer},
       rooms: %{direct: peer, shared: "15550003@g.us"},
       opaque: %{state: ledger, scope: scope}
     }}
  end

  @impl true
  def connect(handle, context) do
    :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    {:ok, profile} = JidoChatBridge.connection_profile(context.connector)
    :ok = ProviderState.bind(handle.opaque.state, context.connector.id)
    :ok = Transport.attach(profile, handle.opaque.state)
    :ok = JidoChatBridge.start_runtime(context.connector)
    scope = handle.opaque.scope
    await_phase(context.connector, scope, :pairing, deadline())
    {:ok, %{qr: qr}} = JidoChatBridge.channel_ingress_status(context.connector)
    :ok = Transport.scan(profile, qr)
    await_phase(context.connector, scope, :connected, deadline())
    {:ok, put_in(handle, [:opaque, :profile], profile)}
  end

  @impl true
  def emit(session, spec) do
    room = Map.fetch!(session.handle.rooms, spec.room)

    message = %Amarula.Msg{
      id: spec.source_id,
      channel: Amarula.Address.parse(room),
      from: Amarula.Address.parse(Map.get(spec, :sender, session.handle.sender.id)),
      to: Amarula.Address.parse(@self_jid),
      type: :text,
      content: spec.content,
      timestamp: DateTime.to_unix(spec.timestamp),
      raw: %{},
      quoted:
        if(spec.thread_id,
          do: %{id: spec.thread_id, channel: Amarula.Address.parse(room)},
          else: nil
        ),
      from_me: Map.get(spec, :from_me, false),
      mentions: if(spec.mention?, do: [Amarula.Address.parse(@self_jid)], else: [])
    }

    :ok = Transport.incoming(session.handle.opaque.profile, message)
    scope = session.scope
    source = spec.source_id

    assert_receive {:channel_integration, ^scope, {:ingress, %{id: ^source}}, :return_from, _},
                   5_000

    {:ok, %{source_id: source, channel_id: room, thread_id: spec.thread_id}}
  end

  @impl true
  def script(session, script), do: ProviderState.script(session.handle.opaque.state, script)

  @impl true
  def deliveries(session), do: ProviderState.deliveries(session.handle.opaque.state)

  @impl true
  def capabilities do
    %{
      direct: true,
      shared: true,
      edits: true,
      threads: true,
      thread_root_lookup: {:unsupported, "Linked-device adapter cannot fetch arbitrary roots"}
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp await_phase(connector, scope, phase, deadline) do
    case JidoChatBridge.channel_ingress_status(connector) do
      {:ok, %{phase: ^phase}} ->
        :ok

      _ ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        assert_receive {:channel_integration, ^scope, {:ingress, _}, :return_from, _}, remaining
        await_phase(connector, scope, phase, deadline)
    end
  end
end
