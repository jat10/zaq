defmodule Zaq.Channels.DeliveryPlan.Step do
  @moduledoc """
  One upload, send or edit operation with explicit dependencies and file indices.

  `prepared` holds a private provider request representation. `message_ref` names
  an existing message or a preceding step result, never an invented provider ID.
  """

  @enforce_keys [:id, :operation, :group_id]
  @derive {Inspect, only: [:id, :operation, :group_id, :depends_on]}
  defstruct [:id, :operation, :group_id, :message_ref, :prepared, file_refs: [], depends_on: []]

  @type t :: %__MODULE__{
          id: term(),
          operation: :upload | :send | :edit,
          group_id: non_neg_integer(),
          message_ref: {:existing, String.t()} | {:result, term()} | nil,
          prepared: term(),
          file_refs: [non_neg_integer()],
          depends_on: [term()]
        }
end
