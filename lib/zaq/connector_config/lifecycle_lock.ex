defmodule Zaq.ConnectorConfig.LifecycleLock do
  @moduledoc """
  Connector-scoped exclusion shared by Engine lifecycle commands and runtime startup.

  Locks span connected BEAM nodes and are released when their holders die. Trusted
  confidential role calls may share a requester token across RPC processes; each
  process releases only its own hold. Same-process nesting retains the outer hold.
  This is execution coordination, not authorization or a partition/quorum protocol.
  Acquire before the node-local runtime lock; never carry a DB row lock across RPC.
  """

  @owner_key {__MODULE__, :owner}

  @doc "Returns the current private requester token for a trusted role hop."
  @spec owner() :: {pid(), reference()} | nil
  def owner, do: Process.get(@owner_key)

  @doc "Identifies saved credential bindings whose startup must be excluded during cleanup."
  @spec saved_binding?(term()) :: boolean()
  def saved_binding?(%{settings: settings}) when is_map(settings),
    do: is_integer(settings["credential_document_id"] || settings[:credential_document_id])

  def saved_binding?(_), do: false

  @doc "Runs a connector operation under one shared lock, retaining nested holds."
  @spec with_lock(pos_integer(), (-> result)) :: result | {:error, :lifecycle_unavailable}
        when result: term()
  def with_lock(id, fun) when is_integer(id) and id > 0 and is_function(fun, 0) do
    key = {__MODULE__, id}

    if Process.get(key) do
      fun.()
    else
      acquire(key, fun)
    end
  end

  defp acquire(key, fun) do
    requester = owner() || {self(), make_ref()}
    nodes = Enum.sort([node() | Node.list()])

    :global.trans(
      {key, requester},
      fn ->
        with_owner(requester, fn -> run_locked(key, fun) end)
      end,
      nodes
    )
  end

  defp run_locked(key, fun) do
    Process.put(key, true)

    try do
      fun.()
    after
      Process.delete(key)
    end
  end

  @doc "Carries a trusted requester into an internal role callback without acquiring a lock."
  @spec with_owner(term(), (-> result)) :: result | {:error, :invalid_lifecycle_owner}
        when result: term()
  def with_owner(nil, fun), do: fun.()

  def with_owner({pid, ref} = requester, fun) when is_pid(pid) and is_reference(ref) do
    previous = Process.put(@owner_key, requester)

    try do
      fun.()
    after
      if previous, do: Process.put(@owner_key, previous), else: Process.delete(@owner_key)
    end
  end

  def with_owner(_, _), do: {:error, :invalid_lifecycle_owner}
end
