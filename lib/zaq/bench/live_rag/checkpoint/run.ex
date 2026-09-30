defmodule Zaq.Bench.LiveRAG.Checkpoint.Run do
  @moduledoc "Persisted singleton corpus run and its lease generation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "liverag_runs" do
    field :input_sha256, :string
    field :config_fingerprint, :string
    field :preparation_contract, :map, default: %{}
    field :status, :string, default: "running"
    field :generation, :integer, default: 0
    field :request_count, :integer, default: 0
    field :attempt_limit, :integer
    field :cooldown_until, :utc_datetime_usec
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
      :preparation_contract,
      :status,
      :generation,
      :request_count,
      :attempt_limit,
      :cooldown_until,
      :lease_token,
      :backend_pid
    ])
    |> validate_required([:id, :input_sha256, :config_fingerprint, :status])
    |> validate_inclusion(:status, ~w(running complete))
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> validate_number(:request_count, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_limit, greater_than: 0)
    |> check_constraint(:id, name: :liverag_runs_singleton)
    |> check_constraint(:generation, name: :liverag_runs_generation_nonnegative)
    |> check_constraint(:request_count, name: :liverag_runs_requests_nonnegative)
    |> check_constraint(:attempt_limit, name: :liverag_runs_attempt_limit_positive)
    |> check_constraint(:status, name: :liverag_runs_status_valid)
  end
end
