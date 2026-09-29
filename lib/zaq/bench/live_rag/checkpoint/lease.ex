defmodule Zaq.Bench.LiveRAG.Checkpoint.Lease do
  @moduledoc "A process-bound corpus run lease backed by one PostgreSQL session lock."

  @enforce_keys [:run_id, :generation, :token, :backend_pid, :owner, :repo]
  @derive {Inspect, only: [:run_id, :generation, :backend_pid]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: integer(),
          generation: pos_integer(),
          token: String.t(),
          backend_pid: integer(),
          owner: pid(),
          repo: pid() | atom()
        }
end
