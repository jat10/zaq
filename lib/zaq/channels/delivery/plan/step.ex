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

  @doc "Returns a JSON-safe reference for a planner-generated step identifier."
  @spec reference(t()) :: {:ok, list()} | {:error, :invalid_step_reference}
  def reference(%__MODULE__{
        id: {:upload, group, batch},
        operation: :upload,
        group_id: group
      })
      when group in 0..2_147_483_647 and batch in 0..2_147_483_647,
      do: {:ok, [:upload, group, batch]}

  def reference(%__MODULE__{id: {operation, group}, operation: operation, group_id: group})
      when operation in [:send, :edit] and group in 0..2_147_483_647,
      do: {:ok, [operation, group]}

  def reference(_step), do: {:error, :invalid_step_reference}
end
