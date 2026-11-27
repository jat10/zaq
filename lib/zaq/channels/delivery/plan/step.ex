defmodule Zaq.Channels.Delivery.Plan.Step do
  @moduledoc """
  Internal upload, send or edit intent with dependencies and original attachment indices.

  `message_ref` identifies a supplied existing message. Provider requests and
  transport results belong to execution, outside this metadata description.
  """

  @enforce_keys [:id, :operation, :group_id]
  @derive {Inspect, only: [:id, :operation, :group_id, :depends_on]}
  defstruct [:id, :operation, :group_id, :message_ref, attachment_refs: [], depends_on: []]

  @type t :: %__MODULE__{
          id: term(),
          operation: :upload | :send | :edit,
          group_id: non_neg_integer(),
          message_ref: {:existing, String.t()} | nil,
          attachment_refs: [non_neg_integer()],
          depends_on: [term()]
        }
end
