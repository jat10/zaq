defmodule ZaqWeb.Live.BO.Communication.LinkedDeviceUI do
  @moduledoc "Owns bounded, generation-tagged pairing polling for the selected BO connector."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]
  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Live.BO.AI.BOActor

  @doc "Begins QR-first onboarding without persisting a connector."
  def new(socket) do
    socket = close(socket)
    generation = make_ref()

    socket
    |> assign(:linked_device_modal, %{
      config_id: nil,
      session: nil,
      name: "Link your WhatsApp account",
      generation: generation,
      attempts: 0,
      status: %{phase: :pending, summary: "Preparing QR code"}
    })
    |> refresh(generation, :begin)
  end

  @doc "Confirms only the active provisional session."
  def confirm(
        %{
          assigns: %{
            linked_device_modal: %{
              config_id: nil,
              generation: generation,
              status: %{phase: :confirm}
            }
          }
        } = socket
      ),
      do: refresh(socket, generation, :confirm)

  def confirm(socket), do: socket

  @doc "Opens one selected connector; previous timers and results become stale."
  def open(socket, config) do
    socket = close(socket)
    generation = make_ref()

    socket
    |> assign(:linked_device_modal, %{
      config_id: config.id,
      name: config.name,
      generation: generation,
      attempts: 0,
      status: %{phase: :pending, summary: "Checking device connection"}
    })
    |> refresh(generation, :status)
  end

  @doc "Clears QR presentation and cancels the next scheduled poll."
  def close(socket) do
    case socket.assigns[:linked_device_modal] do
      %{config_id: nil, session: session} when is_pid(session) ->
        actor = BOActor.build(socket.assigns.current_user)

        Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
          provisional(%{op: :cancel, session: session}, actor)
        end)

      _ ->
        :ok
    end

    if timer = socket.assigns[:linked_device_timer], do: Process.cancel_timer(timer)
    socket |> assign(:linked_device_timer, nil) |> assign(:linked_device_modal, nil)
  end

  @doc "Starts a fresh UI generation for an explicit retry."
  def retry(%{assigns: %{linked_device_modal: %{config_id: nil}}} = socket), do: new(socket)

  def retry(%{assigns: %{linked_device_modal: %{config_id: id}}} = socket) do
    config = Enum.find(socket.assigns.configs, &(&1.id == id and &1.enabled))

    if config do
      socket = close(socket)
      generation = make_ref()

      socket
      |> assign(:linked_device_modal, %{
        config_id: id,
        name: config.name,
        generation: generation,
        attempts: 0,
        status: %{phase: :pending, summary: "Reconnecting device"}
      })
      |> refresh(generation, :retry)
    else
      close(socket)
    end
  end

  def retry(socket), do: socket

  @doc "Only the current modal generation may initiate or accept a poll."
  def refresh(socket, generation, operation \\ :status) do
    case socket.assigns[:linked_device_modal] do
      %{generation: ^generation, config_id: nil} = modal ->
        actor = BOActor.build(socket.assigns.current_user)
        owner = self()

        start_async(socket, {:linked_device, generation}, fn ->
          provisional(%{op: operation, session: modal.session, owner: owner}, actor)
        end)

      %{generation: ^generation, config_id: id} ->
        provider = socket.assigns.provider
        actor = BOActor.build(socket.assigns.current_user)

        start_async(socket, {:linked_device, generation}, fn ->
          request(provider, id, actor, operation)
        end)

      _ ->
        socket
    end
  end

  @doc "Applies current results and bounds polling to three minutes per open/retry."
  def result(socket, generation, result) do
    case socket.assigns[:linked_device_modal] do
      %{generation: ^generation} = modal ->
        status = result_status(result, modal)
        if status[:phase] == :saved, do: send(self(), {:linked_device_saved, status.saved})
        modal = remember_session(modal, status)

        attempts = modal.attempts + 1

        status =
          if attempts >= 90 and status[:phase] in [:pending, :pairing],
            do: %{phase: :expired, summary: "Connection window ended; retry to continue"},
            else: status

        socket =
          assign(socket, :linked_device_modal, %{modal | status: status, attempts: attempts})

        if status[:phase] in [:pending, :pairing] do
          assign(
            socket,
            :linked_device_timer,
            Process.send_after(self(), {:linked_device_poll, generation}, 2000)
          )
        else
          assign(socket, :linked_device_timer, nil)
        end

      _ ->
        discard_stale_session(socket, result)
        socket
    end
  end

  defp result_status({:ok, {:ok, status}}, _) when is_map(status), do: status

  defp result_status({:ok, {:error, :save_failed}}, modal),
    do: Map.put(modal.status, :summary, "Could not save this account. Confirm to retry.")

  defp result_status({:ok, {:error, :identity_changed}}, _),
    do: %{
      phase: :failed,
      summary: "The linked account changed. Retry and confirm the account again."
    }

  defp result_status(_, _),
    do: %{phase: :failed, summary: "Device connection could not be checked or restarted"}

  defp remember_session(%{session: session} = modal, status),
    do: %{modal | session: status[:session] || session}

  defp remember_session(modal, _), do: modal

  defp discard_stale_session(socket, {:ok, {:ok, %{session: session}}}) do
    actor = BOActor.build(socket.assigns.current_user)

    Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
      provisional(%{op: :cancel, session: session}, actor)
    end)
  end

  defp discard_stale_session(_, _), do: :ok

  defp provisional(request, actor) do
    Event.new(request, :channels,
      actor: actor,
      opts: [action: :pair_linked_device, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp request(provider, id, actor, :retry) do
    case dispatch(provider, id, actor, :channel_retry_linked_device) do
      :ok -> request(provider, id, actor, :status)
      error -> error
    end
  end

  defp request(provider, id, actor, :status),
    do: dispatch(provider, id, actor, :channel_ingress_status)

  defp dispatch(provider, id, actor, action) do
    Event.new(%{provider: provider, channel_config_id: id}, :channels,
      actor: actor,
      opts: [action: action, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
