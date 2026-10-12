defmodule Zaq.Engine.Actions.ConfirmLinkedDevice do
  @moduledoc "Persists a server-owned pairing snapshot through the confidential Engine boundary."
  use Jido.Action,
    name: "confirm_linked_device",
    description: "Atomically save a confirmed linked-device connector and session",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.LinkedDeviceConfirmation

  def run(%{request: request}, %{actor: actor, linked_device_runtime: true}) do
    case BOActor.current_user(actor) do
      {:ok, %{role: %{name: "super_admin"}}} ->
        {:ok, %{result: LinkedDeviceConfirmation.save(request)}}

      _ ->
        {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}
end
