defmodule Zaq.Channels.JidoChatBridge.Pairing do
  @moduledoc """
  Host callbacks for provisional adapter pairing under the Jido chat bridge.

  The existing pairing Action authorizes the operator. The adapter package owns
  temporary connections, expiry, cancellation and confirmation retries. These
  callbacks persist through Engine and start the normal communication bridge
  after the package seeds volatile storage. No protocol snapshots reach BO.
  """

  alias Jido.Chat.WhatsApp.PairingSession
  alias Jido.Chat.WhatsApp.Storage.Split
  alias Zaq.Channels.{Bridge, CommunicationBridge}
  alias Zaq.Channels.JidoChatBridge.SessionStorage
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Runs package-owned pairing after the host Action has authorized the operator."
  @spec pair(map(), pos_integer(), map()) :: term()
  def pair(request, user_id, actor) do
    case Bridge.provider_config("whatsapp") do
      %{adapter: adapter} ->
        PairingSession.execute(request, user_id,
          supervisor: Zaq.Channels.BridgeSupervisor,
          attempt_id: Ecto.UUID.generate(),
          adapter: adapter,
          context: actor,
          persist_mfa: {__MODULE__, :confirm_pairing, []},
          start_mfa: {__MODULE__, :start_paired_runtime, []}
        )

      _ ->
        {:error, :pairing_unavailable}
    end
  end

  @doc "Atomically creates the host connector and encrypted durable state."
  @spec confirm_pairing(map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_pairing(actor, request) do
    response =
      request
      |> Map.update!(:records, &Split.encode_records/1)
      |> Event.new(:engine,
        actor: actor,
        opts: [action: :confirm_linked_device, confidential: true, linked_device_runtime: true]
      )
      |> NodeRouter.dispatch()
      |> Map.fetch!(:response)

    with {:ok, config} <- response,
         {:ok, profile} <- SessionStorage.profile(config) do
      binding = %{
        channel_config_id: config.id,
        credential_id: config.settings["credential_document_id"]
      }

      {:ok,
       %{
         receipt: %{id: config.id, name: config.name},
         storage: SessionStorage.storage_options(binding, profile),
         runtime: config
       }}
    end
  end

  @doc "Starts the saved host bridge after the package has seeded volatile state."
  @spec start_paired_runtime(map(), map()) :: term()
  def start_paired_runtime(_actor, config),
    do: CommunicationBridge.sync_config_runtime(nil, config)
end
