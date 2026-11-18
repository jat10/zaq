defmodule Zaq.Channels.DeliveryPlan do
  @moduledoc """
  Private, transient description of one Channel delivery attempt.

  Files retain their original attachment indices. Groups reference those indices;
  steps reference groups and prior step outputs. Prepared request bodies stay in
  the plan until synchronous execution finishes, never in metadata or history.
  Runtime outcomes belong to the executor rather than this description.
  """

  alias Zaq.Channels.DeliveryPlan.Step

  @derive {Inspect, only: [:failure_policy, :placement, :root_message_id]}
  defstruct [
    :failure_policy,
    :placement,
    :root_message_id,
    :requirements,
    files: %{},
    groups: [],
    steps: [],
    preparation_failures: []
  ]

  @type t :: %__MODULE__{
          failure_policy: :continue | :abort,
          placement: :threaded | :independent,
          root_message_id: String.t() | nil,
          requirements: Zaq.Channels.FileRequirements.t() | nil,
          files: %{non_neg_integer() => map()},
          groups: [map()],
          steps: [Step.t()],
          preparation_failures: [map()]
        }
end
