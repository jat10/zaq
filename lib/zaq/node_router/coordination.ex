defmodule Zaq.NodeRouter.Coordination do
  @moduledoc """
  Process-scoped resource coordination for NodeRouter execution.

  A scope shares a requester across nested dispatches, but every executing process
  acquires its own global lock hold. Caller death therefore cannot release a live
  receiver's hold. Same-process nesting retains the outer hold. Context is carried
  privately by the router, never in event payloads, responses or observer broadcasts.

  Resources are opaque trusted terms. Callers nesting different resources must
  acquire them in a consistent order. Coordination covers connected BEAM nodes;
  it is neither authorization nor partition fencing, and does not roll back effects.
  Arbitrary spawned processes do not inherit a scope; use routed dispatch for handoff.

  Contention retries use a 5-second default budget, configurable through
  `:coordination_timeout`. Budgets never expire a holder. Handoffs carry remaining
  milliseconds instead of node-local monotonic timestamps; transport and individual
  distributed lock calls are not bounded by this contention budget.
  """

  @context_key {__MODULE__, :context}
  @default_timeout 5_000
  @retry_interval 25
  @type context :: %{optional(term()) => {{pid(), reference()}, [node()], integer()}}
  @type handoff :: %{optional(term()) => {{pid(), reference()}, [node()], non_neg_integer()}}

  @doc "Returns the scopes held by the current process for internal router handoff."
  @spec context() :: context()
  def context, do: Process.get(@context_key, %{})

  @doc "Captures active scopes and an optional trusted event resource before process handoff."
  @spec capture(term()) :: context()
  def capture(opts) when is_list(opts) do
    timeout = Keyword.get(opts, :coordination_timeout, @default_timeout)

    unless is_integer(timeout) and timeout >= 0 do
      raise ArgumentError, "coordination_timeout must be a non-negative integer in milliseconds"
    end

    case Keyword.fetch(opts, :coordination) do
      {:ok, resource} ->
        Map.put_new_lazy(context(), resource, fn -> new_scope(timeout) end)

      :error ->
        context()
    end
  end

  def capture(_opts), do: context()

  defp new_scope(timeout) do
    deadline =
      Enum.reduce(context(), now() + timeout, fn {_, {_, _, parent}}, acc -> min(parent, acc) end)

    {{self(), make_ref()}, Enum.sort([node() | Node.list()]), deadline}
  end

  @doc "Exports remaining acquisition budgets; monotonic timestamps must not cross BEAM nodes."
  @spec export(context()) :: handoff()
  def export(scopes) do
    Map.new(scopes, fn {resource, {requester, nodes, deadline}} ->
      {resource, {requester, nodes, max(deadline - now(), 0)}}
    end)
  end

  @doc "Returns the remaining budget for acknowledging a local async handoff."
  @spec remaining_timeout(context()) :: non_neg_integer()
  def remaining_timeout(scopes) when map_size(scopes) > 0 do
    scopes
    |> Map.values()
    |> Enum.map(fn {_, _, deadline} -> max(deadline - now(), 0) end)
    |> Enum.min()
  end

  @doc "Rebases received budgets onto this node's monotonic clock."
  @spec import(handoff()) :: context()
  def import(scopes) do
    Map.new(scopes, fn {resource, {requester, nodes, remaining}} ->
      {resource, {requester, nodes, now() + remaining}}
    end)
  end

  @doc "Executes under captured router scopes, independently holding each resource in this process."
  @spec run(context(), (-> result)) :: result | {:error, :coordination_timeout}
        when result: term()
  def run(scopes, fun) when is_map(scopes) and is_function(fun, 0) do
    scopes |> Enum.sort() |> acquire(fun)
  end

  defp acquire([], fun), do: fun.()

  defp acquire([{resource, {requester, nodes, deadline}} | rest], fun) do
    case Map.fetch(context(), resource) do
      {:ok, {^requester, ^nodes, _}} -> acquire(rest, fun)
      {:ok, _} -> raise ArgumentError, "conflicting coordination scope"
      :error -> hold(resource, requester, nodes, deadline, fn -> acquire(rest, fun) end)
    end
  end

  defp hold(resource, {pid, ref} = requester, nodes, deadline, fun)
       when is_pid(pid) and is_reference(ref) and is_list(nodes) do
    lock = {{__MODULE__, resource}, requester}

    with :ok <- lock_until(lock, nodes, deadline) do
      run_locked(resource, requester, nodes, deadline, lock, fun)
    end
  end

  defp lock_until(lock, nodes, deadline) do
    if :global.set_lock(lock, nodes, 0) do
      :ok
    else
      case deadline - now() do
        remaining when remaining > 0 ->
          receive do
          after
            min(remaining, @retry_interval) -> retry_lock(lock, nodes, deadline)
          end

        _ ->
          {:error, :coordination_timeout}
      end
    end
  end

  defp retry_lock(lock, nodes, deadline) do
    if now() < deadline,
      do: lock_until(lock, nodes, deadline),
      else: {:error, :coordination_timeout}
  end

  defp run_locked(resource, requester, nodes, deadline, lock, fun) do
    previous = context()
    Process.put(@context_key, Map.put(previous, resource, {requester, nodes, deadline}))

    try do
      fun.()
    after
      if map_size(previous) == 0,
        do: Process.delete(@context_key),
        else: Process.put(@context_key, previous)

      :global.del_lock(lock, nodes)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
