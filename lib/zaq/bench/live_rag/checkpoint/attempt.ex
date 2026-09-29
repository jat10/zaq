defmodule Zaq.Bench.LiveRAG.Checkpoint.Attempt do
  @moduledoc "Redacted, numbered outcome or explicit retry request for one chunk."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Bench.LiveRAG.Checkpoint.Chunk

  schema "liverag_attempts" do
    belongs_to :run_chunk, Chunk
    field :attempt_number, :integer
    field :kind, :string
    field :error_code, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Accepts only fixed outcome kinds and redacted error codes."
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:run_chunk_id, :attempt_number, :kind, :error_code])
    |> validate_required([:run_chunk_id, :attempt_number, :kind])
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_inclusion(:kind, ~w(success failure retry_requested))
    |> validate_format(:error_code, ~r/\A[a-z][a-z0-9_]*\z/)
    |> validate_length(:error_code, max: 64)
    |> unique_constraint([:run_chunk_id, :attempt_number])
    |> foreign_key_constraint(:run_chunk_id)
    |> check_constraint(:kind, name: :liverag_attempts_kind_valid)
  end
end
