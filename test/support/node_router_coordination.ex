defmodule Zaq.TestSupport.NodeRouterCoordination do
  @moduledoc false

  alias Zaq.NodeRouter.Coordination

  def coordinate(resource, operation, opts \\ []) do
    Coordination.run(Coordination.capture(Keyword.put(opts, :coordination, resource)), operation)
  end
end
