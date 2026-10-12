defmodule Zaq.Channels.Actions.PairLinkedDevice do
  @moduledoc "Confidential operator Action for provisional WhatsApp pairing; never an agent tool."
  use Jido.Action,
    name: "pair_linked_device",
    description: "Pair and confirm a linked device before creating its connector",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Accounts.BOActor
  alias Zaq.Channels.LinkedDevice.Session

  def run(%{request: request}, %{actor: actor, confidential: true}) do
    case BOActor.current_user(actor) do
      {:ok, %{id: id, role: %{name: "super_admin"}}} ->
        {:ok, %{result: Session.execute(request, id, actor)}}

      _ ->
        {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}
end
