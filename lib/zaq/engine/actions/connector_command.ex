defmodule Zaq.Engine.Actions.ConnectorCommand do
  @moduledoc "Shared confidential execution boundary for super-admin connector Actions."

  alias Zaq.Accounts.BOActor

  @doc "Validates trusted actor context, then wraps the Action's own operation result."
  @spec run(term(), term(), (term(), map(), keyword() -> term())) ::
          {:ok, %{result: term()}} | {:error, :unauthorized}
  def run(%{request: request}, %{actor: actor, confidential: true} = context, execute) do
    with {:ok, _user} <- BOActor.current_super_admin(actor) do
      {:ok, %{result: execute.(request, actor, Map.get(context, :opts, []))}}
    end
  end

  def run(_, _, _), do: {:error, :unauthorized}
end
