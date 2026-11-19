defmodule Zaq.Channels.DeliveryPlan do
  @moduledoc """
  Private, transient description of one Channel delivery attempt.

  Groups and steps reference original attachment indices in Outgoing.Delivery.
  The plan contains metadata decisions only. Acquired bytes, prepared requests,
  elected roots and operation outcomes belong to the executor runtime.
  """

  alias Zaq.Channels.DeliveryPlan.Step

  @derive {Inspect, only: [:failure_policy, :placement]}
  defstruct [
    :failure_policy,
    :placement,
    :requirements,
    groups: [],
    steps: [],
    preparation_failures: []
  ]

  @type t :: %__MODULE__{
          failure_policy: :continue | :abort,
          placement: :threaded | :independent,
          requirements: Zaq.Channels.TransportRequirements.t() | nil,
          groups: [map()],
          steps: [Step.t()],
          preparation_failures: [map()]
        }
end
