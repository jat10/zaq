defmodule Zaq.Channels.Delivery.Plan do
  @moduledoc """
  Internal metadata decisions for a Channel attachment delivery attempt.

  Groups and steps reference original indices in `Outgoing.attachments`. Records,
  acquired bytes, prepared requests and execution outcomes remain outside the plan.
  Requirements retain unresolved limits; a plan does not attest provider acceptance
  or actual content size. Execution must validate acquired content and requests.
  """

  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements

  @enforce_keys [:requirements, :placement, :groups, :steps]
  @derive {Inspect, only: [:placement]}
  defstruct [:requirements, :placement, :groups, :steps]

  @type group :: %{id: non_neg_integer(), attachment_refs: [non_neg_integer()]}
  @type t :: %__MODULE__{
          requirements: TransportRequirements.t(),
          placement: :threaded | :independent,
          groups: [group()],
          steps: [Step.t()]
        }
end
