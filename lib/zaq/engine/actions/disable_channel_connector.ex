defmodule Zaq.Engine.Actions.DisableChannelConnector do
  @moduledoc "Confidential administrator Action for confirmed connector disable and logout."

  use Jido.Action,
    name: "disable_channel_connector",
    description: "Prepare or execute a scoped connector disable with adapter logout",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Engine.Actions.ConnectorCommand
  alias Zaq.Engine.ConnectorLifecycle

  @impl Jido.Action
  def run(params, context), do: ConnectorCommand.run(params, context, &execute/3)

  defp execute(%{op: :context, channel_config_id: id, provider: provider, kind: kind}, _, _),
    do: ConnectorLifecycle.context(id, provider, kind)

  defp execute(%{op: :disable} = request, actor, opts),
    do: ConnectorLifecycle.disable(request, actor, opts)

  defp execute(_, _, _), do: {:error, :invalid_request}
end
