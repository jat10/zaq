defmodule Zaq.Bench.LiveRAG.Checkpoint.Run do
  @moduledoc "Persisted singleton corpus run and its lease generation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "liverag_runs" do
    field :input_sha256, :string
    field :config_fingerprint, :string
    field :status, :string, default: "running"
    field :generation, :integer, default: 0
    field :lease_token, Ecto.UUID
    field :backend_pid, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Validates a corpus run without admitting arbitrary status or generation values."
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :input_sha256,
      :config_fingerprint,
      :status,
      :generation,
      :lease_token,
      :backend_pid
    ])
    |> validate_required([:id, :input_sha256, :config_fingerprint, :status])
    |> validate_inclusion(:status, ~w(running complete))
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> check_constraint(:id, name: :liverag_runs_singleton)
    |> check_constraint(:generation, name: :liverag_runs_generation_nonnegative)
    |> check_constraint(:status, name: :liverag_runs_status_valid)
  end
end
