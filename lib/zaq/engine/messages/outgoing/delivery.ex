defmodule Zaq.Engine.Messages.Outgoing.Delivery do
  @moduledoc """
  Explicit outgoing attachment selection and its bounded selection error.

  The plan is private, transient Channel data. Producers and restored pipeline
  results carry selection only; execution plans never cross back into Engine.
  """

  alias Zaq.Contracts.Record

  @derive {Inspect, only: [:error]}
  defstruct attachments: [], error: nil, plan: nil

  @type t :: %__MODULE__{
          attachments: [Record.t()],
          error: :invalid_attachment_selection | nil,
          plan: Zaq.Channels.Delivery.Plan.t() | nil
        }

  @doc "Restores selection from typed or atom/string-keyed pipeline data, discarding plans."
  @spec from_result(map()) :: t()
  def from_result(result) do
    case fetch(result, :delivery) do
      %{} = delivery ->
        %__MODULE__{
          attachments: fetch(delivery, :attachments, []),
          error: fetch(delivery, :error)
        }

      _ ->
        %__MODULE__{
          attachments: fetch(result, :attachments, []),
          error: fetch(result, :attachment_error)
        }
    end
  end

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
