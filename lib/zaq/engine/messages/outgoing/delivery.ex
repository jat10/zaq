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
          error: :invalid_attachment_selection | %{reason: atom(), failures: [map()]} | nil,
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

  @doc "Returns bounded rejected-file facts from typed or restored selection errors."
  def selection_failures(error) when is_map(error) do
    case fetch(error, :failures, []) do
      failures when is_list(failures) ->
        failures
        |> Enum.take(100)
        |> Enum.flat_map(&selection_failure/1)

      _ ->
        []
    end
  end

  def selection_failures(_error), do: []

  defp selection_failure(failure) when is_map(failure) do
    selection_failure(
      fetch(failure, :record_id),
      fetch(failure, :name),
      fetch(failure, :reason),
      fetch(failure, :size),
      fetch(failure, :limit)
    )
  end

  defp selection_failure(_failure), do: []

  defp selection_failure(id, name, "file_too_large", size, limit)
       when is_binary(id) and is_binary(name) and byte_size(name) <= 1024 and
              is_integer(size) and is_integer(limit) and limit > 0 and size > limit do
    [%{record_id: id, name: name, reason: "file_too_large", size: size, limit: limit}]
  end

  defp selection_failure(_id, _name, _reason, _size, _limit), do: []

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
