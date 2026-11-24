defmodule Zaq.Channels.Delivery.Plan do
  @moduledoc """
  Private, transient description of one Channel delivery attempt.

  Groups and steps reference original attachment indices in Outgoing.Delivery.
  The plan contains metadata decisions only. Acquired bytes, prepared requests,
  elected roots and operation outcomes belong to the executor runtime.
  """

  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements

  @derive {Inspect, only: [:placement]}
  defstruct [
    :placement,
    :requirements,
    groups: [],
    steps: [],
    preparation_failures: []
  ]

  @type t :: %__MODULE__{
          placement: :threaded | :independent,
          requirements: Zaq.Channels.TransportRequirements.t() | nil,
          groups: [map()],
          steps: [Step.t()],
          preparation_failures: [map()]
        }

  @doc """
  Derives policy from resolved constraints or a text-only failure fallback.

  Returns nil for invalid constraints or attachment operations without requirements.
  """
  @spec failure_policy(t()) :: :continue | :abort | nil
  def failure_policy(%__MODULE__{requirements: %TransportRequirements{} = requirements}) do
    if TransportRequirements.validate(requirements) == :ok, do: requirements.failure_policy
  end

  def failure_policy(%__MODULE__{
        requirements: nil,
        groups: [%{id: group_id, attachment_refs: []}],
        steps: [
          %Step{
            operation: :send,
            group_id: group_id,
            attachment_refs: [],
            depends_on: [],
            message_ref: nil
          }
        ],
        preparation_failures: [_ | _]
      }),
      do: :continue

  def failure_policy(_plan), do: nil
end
