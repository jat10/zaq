defmodule Zaq.Channels.DeliveryError do
  @moduledoc """
  ZAQ delivery failure facts from attachment selection or a communication bridge.

  `message` is safe for presentation; `reason` retains the original error for
  internal diagnostics and is omitted from inspection. A normalized execution
  report can use `cause` to retain the underlying transport reason privately.
  `stage` identifies
  selection, configuration, preparation, execution or transport, and `delivery` distinguishes a known unsent
  message from an unconfirmed outcome. These are facts, not retry instructions.
  Channels orchestration owns fallback decisions. Bridges own transport mappings.
  """

  @enforce_keys [:reason, :message, :stage, :delivery]
  @derive {Inspect, only: [:message, :stage, :delivery]}
  defstruct [:reason, :message, :stage, :delivery, :step_id, :group_id, :cause]

  @type t :: %__MODULE__{
          reason: term(),
          message: String.t(),
          stage: :selection | :configuration | :preparation | :execution | :upload | :transport,
          delivery: :not_sent | :unconfirmed,
          step_id: term(),
          group_id: non_neg_integer() | nil,
          cause: term()
        }
end
