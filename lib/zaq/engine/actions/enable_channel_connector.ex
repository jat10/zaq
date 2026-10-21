defmodule Zaq.Engine.Actions.EnableChannelConnector do
  @moduledoc """
  Confidential super-admin Action for explicit connector enablement.

  Context preparation and execution validate the current BO user. Engine owns
  scope, revision and persistence; Channels owns runtime reconciliation. Runtime
  failure leaves the enabled connector pending for an explicit idempotent retry.
  """

  use Jido.Action,
    name: "enable_channel_connector",
    description: "Prepare or execute explicit scoped connector enablement",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Engine.Actions.ConnectorCommand
  alias Zaq.Engine.ConnectorLifecycle

  @impl Jido.Action
  def run(params, context), do: ConnectorCommand.run(params, context, &execute/3)

  defp execute(%{op: :context, channel_config_id: id, provider: provider, kind: kind}, _, _)
       when is_binary(provider) and is_binary(kind),
       do: ConnectorLifecycle.context(id, provider, kind)

  defp execute(%{op: :enable} = request, actor, opts),
    do: ConnectorLifecycle.enable(request, actor, opts)

  defp execute(_, _, _), do: {:error, :invalid_request}
end
