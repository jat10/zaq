defmodule Zaq.Channels.Delivery.Plan.Step do
  @moduledoc """
  One upload, send or edit operation with explicit dependencies and attachment indices.

  `prepared` is filled only on the executor's operation copy; completed plan steps
  contain no provider request bytes. `message_ref` names
  an existing message or a preceding step result, never an invented provider ID.
  """

  @enforce_keys [:id, :operation, :group_id]
  @derive {Inspect, only: [:id, :operation, :group_id, :depends_on]}
  defstruct [
    :id,
    :operation,
    :group_id,
    :message_ref,
    :prepared,
    attachment_refs: [],
    depends_on: []
  ]

  @type t :: %__MODULE__{
          id: term(),
          operation: :upload | :send | :edit,
          group_id: non_neg_integer(),
          message_ref: {:existing, String.t()} | {:result, term()} | nil,
          prepared: term(),
          attachment_refs: [non_neg_integer()],
          depends_on: [term()]
        }
end
