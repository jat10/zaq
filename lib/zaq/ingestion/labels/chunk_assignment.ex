defmodule Zaq.Ingestion.Labels.ChunkAssignment do
  @moduledoc "Effective chunk category decision, manual value and automatic result provenance."
  use Ecto.Schema
  import Ecto.Changeset
  alias Zaq.Ingestion.Labels.AssignmentValue

  schema "chunk_label_assignments" do
    belongs_to :label, Zaq.Ingestion.Labels.Label
    belongs_to :chunk, Zaq.Ingestion.Chunk
    field :value, :string
    field :selected, :boolean
    field :origin, Ecto.Enum, values: [:manual, :automatic], default: :manual
    field :probability, :float
    field :definition_version, :integer
    field :generation, :integer
    field :request_id, Ecto.UUID
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Sets a manual decision with server-owned identity and provenance."
  def decision_changeset(assignment, selected, value \\ :unchanged) do
    assignment
    |> change(
      selected: selected,
      origin: :manual,
      probability: nil,
      definition_version: nil,
      generation: nil,
      request_id: nil
    )
    |> AssignmentValue.put(selected, value)
    |> validate_required([:selected, :label_id, :chunk_id])
    |> unique_constraint([:chunk_id, :label_id])
    |> foreign_key_constraint(:label_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
