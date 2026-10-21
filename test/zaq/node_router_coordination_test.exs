defmodule Zaq.NodeRouterCoordinationFixtures do
  def event(module, function, args) do
    Zaq.Event.new(%{module: module, function: function, args: args}, :bo,
      opts: [action: :invoke, confidential: true]
    )
  end

  def remote_runtime(supervisor) do
    %{
      whereis_fn: fn _ -> nil end,
      node_list_fn: fn -> [:receiver@host] end,
      rpc_call_fn: fn
        _, Process, :whereis, [_] ->
          self()

        _, module, function, args ->
          supervisor
          |> Task.Supervisor.async_nolink(fn -> apply(module, function, args) end)
          |> Task.await()
      end
    }
  end
end

defmodule Zaq.NodeRouterCoordinationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Zaq.NodeRouterCoordinationFixtures, only: [event: 3, remote_runtime: 1]

  alias Zaq.{Event, NodeRouter}

  test "nested local dispatch retains the operation hold until the outer scope returns" do
    resource = {__MODULE__, make_ref()}
    observer = self()

    root =
      Task.async(fn ->
        NodeRouter.with_coordination(resource, fn ->
          event = event(__MODULE__, :nested, [resource])
          assert NodeRouter.dispatch(event, local_runtime()).response == :nested
          send(observer, :outer_held)
          receive do: (:finish -> :ok)
        end)
      end)

    assert_receive :outer_held
    contender = contender(resource)
    refute_receive :entered, 50
    send(root.pid, :finish)
    assert Task.await(root) == :ok
    assert Task.await(contender) == :entered
  end

  test "a remote receiver retains its hold after its caller dies" do
    resource = {__MODULE__, make_ref()}
    observer = self()
    supervisor = start_supervised!(Task.Supervisor)

    {:ok, root} =
      Task.Supervisor.start_child(supervisor, fn ->
        NodeRouter.with_coordination(resource, fn ->
          NodeRouter.dispatch(event(__MODULE__, :barrier, [observer]), remote_runtime(supervisor))
        end)
      end)

    assert_receive {:receiver_held, receiver}
    monitor = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, :killed}
    contender = contender(resource)
    refute_receive :entered, 50
    send(receiver, :finish)
    assert Task.await(contender) == :entered
  end

  test "an explicitly coordinated event takes the same scope locally and remotely" do
    resource = {__MODULE__, make_ref()}
    supervisor = start_supervised!(Task.Supervisor)

    for runtime <- [local_runtime(), remote_runtime(supervisor)] do
      event = event(__MODULE__, :nested, [resource])
      event = %{event | opts: Keyword.put(event.opts, :coordination, resource)}
      assert NodeRouter.dispatch(event, runtime).response == :nested
    end

    refute NodeRouter.coordinated?(resource)
  end

  property "nested scopes restore ownership after exceptions for arbitrary resource keys" do
    check all(key <- binary(max_length: 30), max_runs: 20) do
      resource = {__MODULE__, key, make_ref()}

      assert_raise RuntimeError, "abort", fn ->
        NodeRouter.with_coordination(resource, fn ->
          NodeRouter.with_coordination(resource, fn -> raise "abort" end)
        end)
      end

      refute NodeRouter.coordinated?(resource)
      assert :released == NodeRouter.with_coordination(resource, fn -> :released end)
    end
  end

  test "independent resources can execute while another resource is held" do
    NodeRouter.with_coordination({__MODULE__, make_ref()}, fn ->
      task =
        Task.async(fn -> NodeRouter.with_coordination(make_ref(), fn -> :independent end) end)

      assert Task.await(task) == :independent
    end)
  end

  test "async dispatch captures its parent scope before handing off to another process" do
    resource = {__MODULE__, make_ref()}
    supervisor = start_supervised!(Task.Supervisor)

    runtime =
      Map.put(local_runtime(), :async_start_fn, &Task.Supervisor.start_child(supervisor, &1))

    event = event(__MODULE__, :barrier, [self()])
    event = %{event | next_hop: %{event.next_hop | type: :async}}

    NodeRouter.with_coordination(resource, fn ->
      assert NodeRouter.dispatch(event, runtime).response == nil
      assert_receive {:receiver_held, receiver}
      send(self(), {:async_receiver, receiver})
    end)

    assert_receive {:async_receiver, receiver}
    contender = contender(resource)
    refute_receive :entered, 50
    send(receiver, :finish)
    assert Task.await(contender) == :entered
  end

  test "fanout applies the declared scope to both local and remote execution" do
    resource = {__MODULE__, make_ref()}
    supervisor = start_supervised!(Task.Supervisor)
    runtime = Map.merge(remote_runtime(supervisor), local_runtime())
    event = event(__MODULE__, :nested, [resource])
    event = %{event | opts: Keyword.put(event.opts, :coordination, resource)}

    assert {:ok, [%Event{response: :nested}, %Event{response: :nested}]} =
             NodeRouter.dispatch_all(event, runtime)

    refute NodeRouter.coordinated?(resource)
  end

  def nested(resource) do
    true = NodeRouter.coordinated?(resource)
    NodeRouter.with_coordination(resource, fn -> :nested end)
  end

  def barrier(observer) do
    send(observer, {:receiver_held, self()})
    receive do: (:finish -> :ok)
  end

  defp contender(resource) do
    observer = self()

    task =
      Task.async(fn ->
        send(observer, :contending)

        NodeRouter.with_coordination(resource, fn ->
          send(observer, :entered)
          :entered
        end)
      end)

    assert_receive :contending
    task
  end

  defp local_runtime, do: %{whereis_fn: fn _ -> self() end}
end

defmodule Zaq.NodeRouterCoordinationTimeoutTest do
  use ExUnit.Case, async: false

  import Zaq.NodeRouterCoordinationFixtures, only: [event: 3, remote_runtime: 1]

  alias Zaq.{Event, NodeRouter}

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "default waits five seconds while an explicit thirty-second caller can keep waiting",
       ctx do
    resource = {__MODULE__, make_ref()}
    holder = hold(ctx.supervisor, resource)

    default =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        NodeRouter.with_coordination(resource, fn -> :unexpected end)
      end)

    longer =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        NodeRouter.with_coordination(resource, fn -> :entered end, coordination_timeout: 30_000)
      end)

    try do
      # Elapsed time is the acquisition-budget contract under test.
      assert Task.yield(default, 100) == nil
      assert Task.await(default, 6_000) == {:error, :coordination_timeout}
      assert Task.yield(longer, 0) == nil
      send(holder.pid, :release)
      assert Task.await(holder) == :released
      assert Task.await(longer) == :entered
    after
      Enum.each([holder, default, longer], &Task.shutdown(&1, :brutal_kill))
    end
  end

  test "dispatch timeout stays in the event response and never invokes the handler", ctx do
    resource = {__MODULE__, make_ref()}
    holder = hold(ctx.supervisor, resource)

    event =
      event(__MODULE__, :notify, [self()])
      |> Map.update!(:opts, &Keyword.merge(&1, coordination: resource, coordination_timeout: 30))

    try do
      assert %Event{response: {:error, :coordination_timeout}} =
               NodeRouter.dispatch(event, local_runtime())

      assert {:error, :coordination_timeout} = NodeRouter.dispatch_all(event, local_runtime())
      refute_received :handler_ran
      refute NodeRouter.coordinated?(resource)
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  test "nested remote dispatch carries remaining budget and releases partial acquisitions", ctx do
    outer = {__MODULE__, :outer, make_ref()}
    blocked = {__MODULE__, :blocked, make_ref()}
    holder = hold(ctx.supervisor, blocked)
    observer = self()

    runtime = remote_runtime(ctx.supervisor)

    caller =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        NodeRouter.with_coordination(
          outer,
          fn ->
            # Consume most of the budget before the remote handoff. A receiver
            # that resets it to the 5-second default will miss the assertion bound.
            Process.send_after(self(), :budget_elapsed, 150)
            receive do: (:budget_elapsed -> :ok)

            NodeRouter.dispatch(event(__MODULE__, :acquire_nested, [blocked, observer]), runtime)
          end,
          coordination_timeout: 200
        )
      end)

    try do
      assert %Event{response: {:error, :coordination_timeout}} = Task.await(caller, 1_000)
      refute_received :handler_ran
      assert :released = NodeRouter.with_coordination(outer, fn -> :released end)
    after
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  test "expiry never interrupts an operation that already owns the resource", ctx do
    resource = {__MODULE__, make_ref()}

    NodeRouter.with_coordination(
      resource,
      fn ->
        Process.send_after(self(), :past_deadline, 30)
        receive do: (:past_deadline -> :ok)
        assert NodeRouter.coordinated?(resource)
        assert :nested = NodeRouter.with_coordination(resource, fn -> :nested end)

        contender =
          Task.Supervisor.async_nolink(ctx.supervisor, fn ->
            NodeRouter.with_coordination(resource, fn -> :unexpected end, coordination_timeout: 0)
          end)

        assert Task.await(contender) == {:error, :coordination_timeout}
      end,
      coordination_timeout: 10
    )
  end

  test "invalid timeouts are rejected before running the operation" do
    for timeout <- [-1, nil, :infinity, "5000"] do
      assert_raise ArgumentError, fn ->
        NodeRouter.with_coordination(make_ref(), fn -> flunk("must not execute") end,
          coordination_timeout: timeout
        )
      end
    end
  end

  test "a stuck holder yields a bounded error to a competing operation", ctx do
    resource = {__MODULE__, make_ref()}
    observer = self()
    supervisor = ctx.supervisor

    holder = hold(supervisor, resource)

    waiter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(observer, :waiter_started)
        NodeRouter.with_coordination(resource, fn -> :entered end, coordination_timeout: 50)
      end)

    try do
      assert_receive :waiter_started

      assert Task.await(waiter, 1_000) == {:error, :coordination_timeout}

      # A timed-out waiter must not release the live holder's lock.
      assert {:error, :coordination_timeout} =
               NodeRouter.with_coordination(resource, fn -> :entered end, coordination_timeout: 0)

      send(holder.pid, :release)
      assert Task.await(holder) == :released

      assert :entered = NodeRouter.with_coordination(resource, fn -> :entered end)
    after
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(waiter, :brutal_kill)
    end
  end

  test "an accepted async continuation prevents another operation entering before it starts",
       ctx do
    resource = {__MODULE__, make_ref()}
    observer = self()
    supervisor = ctx.supervisor
    history = start_supervised!({Agent, fn -> [] end})

    runtime = %{
      whereis_fn: fn _ -> self() end,
      async_start_fn: fn work ->
        Task.Supervisor.start_child(supervisor, fn ->
          send(observer, {:handoff_waiting, self()})
          receive do: (:resume_handoff -> work.())
          send(observer, :continuation_finished)
        end)
      end
    }

    event = event(__MODULE__, :record_operation, [history, :continuation])

    event = %{event | next_hop: %{event.next_hop | type: :async}}

    parent =
      Task.Supervisor.async_nolink(supervisor, fn ->
        NodeRouter.with_coordination(resource, fn ->
          record_operation(history, :parent)
          assert NodeRouter.dispatch(event, runtime).response == nil
        end)
      end)

    assert_receive {:handoff_waiting, receiver}
    assert Task.yield(parent, 30) == nil

    assert {:error, :coordination_timeout} =
             NodeRouter.with_coordination(resource, fn -> :entered end, coordination_timeout: 0)

    contender =
      Task.Supervisor.async_nolink(supervisor, fn ->
        NodeRouter.with_coordination(resource, fn ->
          record_operation(history, :interloper)
        end)
      end)

    try do
      assert Task.yield(contender, 30) == nil
      send(receiver, :resume_handoff)
      assert Task.await(parent) == true
      assert_receive :continuation_finished, 1_000
      assert Task.await(contender) == :ok

      assert Agent.get(history, & &1) == [:parent, :continuation, :interloper]
    after
      send(receiver, :resume_handoff)
      Task.shutdown(contender, :brutal_kill)
      Task.shutdown(parent, :brutal_kill)
    end
  end

  def record_operation(history, operation) do
    Agent.update(history, &(&1 ++ [operation]))
  end

  def notify(observer), do: send(observer, :handler_ran)

  def acquire_nested(resource, observer) do
    NodeRouter.with_coordination(resource, fn -> notify(observer) end,
      coordination_timeout: 30_000
    )
  end

  defp hold(supervisor, resource) do
    observer = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        NodeRouter.with_coordination(resource, fn ->
          send(observer, :held)
          receive do: (:release -> :released)
        end)
      end)

    assert_receive :held
    holder
  end

  defp local_runtime, do: %{whereis_fn: fn _ -> self() end, node_list_fn: fn -> [] end}
end

defmodule Zaq.NodeRouterAsyncHandoffTest do
  use ExUnit.Case, async: true

  alias Zaq.NodeRouter
  alias Zaq.NodeRouter.{AsyncHandoff, Coordination}

  setup do
    %{supervisor: start_supervised!(Task.Supervisor), resource: {__MODULE__, make_ref()}}
  end

  test "worker retains ownership after acknowledgement and caller exit", ctx do
    observer = self()

    parent =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        scopes = Coordination.capture(coordination: ctx.resource)

        AsyncHandoff.start(scopes, &Task.Supervisor.start_child(ctx.supervisor, &1), fn ->
          send(observer, {:executing, self()})
          receive do: (:finish -> :ok)
        end)
      end)

    assert Task.await(parent) == :ok
    assert_receive {:executing, worker}

    assert {:error, :coordination_timeout} =
             NodeRouter.with_coordination(ctx.resource, fn -> :entered end,
               coordination_timeout: 0
             )

    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert :entered = NodeRouter.with_coordination(ctx.resource, fn -> :entered end)
  end

  test "timeout cancels a delayed worker before releasing caller holds", ctx do
    observer = self()
    scopes = Coordination.capture(coordination: ctx.resource, coordination_timeout: 40)

    assert {:error, :coordination_timeout} =
             AsyncHandoff.start(scopes, delayed_start(ctx.supervisor, observer), fn ->
               send(observer, :executed)
             end)

    assert_receive {:waiting, worker}
    refute Process.alive?(worker)
    send(worker, :resume)
    refute_receive :executed, 30
    assert :entered = NodeRouter.with_coordination(ctx.resource, fn -> :entered end)
  end

  test "caller death before commit cancels execution", ctx do
    observer = self()

    parent =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        scopes = Coordination.capture(coordination: ctx.resource)

        AsyncHandoff.start(scopes, delayed_start(ctx.supervisor, observer), fn ->
          send(observer, :executed)
        end)
      end)

    assert_receive {:waiting, worker}
    Task.shutdown(parent, :brutal_kill)
    monitor = Process.monitor(worker)
    send(worker, :resume)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    refute_receive :executed, 30
    assert :entered = NodeRouter.with_coordination(ctx.resource, fn -> :entered end)
  end

  test "worker death and startup failure are returned to the caller", ctx do
    scopes = Coordination.capture(coordination: ctx.resource)

    assert {:error, {:coordination_handoff_failed, :unavailable}} =
             AsyncHandoff.start(scopes, fn _ -> {:error, :unavailable} end, fn ->
               flunk("executed")
             end)

    assert {:error, {:coordination_handoff_failed, reason}} =
             AsyncHandoff.start(
               scopes,
               fn _ ->
                 Task.Supervisor.start_child(ctx.supervisor, fn -> exit(:shutdown) end)
               end,
               fn -> flunk("executed") end
             )

    assert reason in [:shutdown, :noproc]

    assert :entered = NodeRouter.with_coordination(ctx.resource, fn -> :entered end)
  end

  test "caller death after ready but before commit releases prepared worker without executing",
       ctx do
    observer = self()

    parent =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        scopes = Coordination.capture(coordination: ctx.resource)

        start_worker = fn work ->
          {:ok, worker} = Task.Supervisor.start_child(ctx.supervisor, work)

          receive do
            {_ref, :ready} -> send(observer, {:prepared, worker})
          end

          receive do: (:return_start -> {:ok, worker})
        end

        AsyncHandoff.start(scopes, start_worker, fn -> send(observer, :executed) end)
      end)

    assert_receive {:prepared, worker}
    monitor = Process.monitor(worker)
    Task.shutdown(parent, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    refute_receive :executed, 30
    assert :entered = NodeRouter.with_coordination(ctx.resource, fn -> :entered end)
  end

  defp delayed_start(supervisor, observer) do
    fn work ->
      Task.Supervisor.start_child(supervisor, fn ->
        send(observer, {:waiting, self()})
        receive do: (:resume -> work.())
      end)
    end
  end
end

defmodule Zaq.NodeRouterCoordinationPeerTest do
  use ExUnit.Case, async: false
  alias Zaq.TestSupport.NodeRouterCoordinationPeer

  @tag timeout: 60_000
  test "real RPC cleanup excludes startup after the originating process dies" do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    {origin, _} = peer("origin")
    {receiver, receiver_node} = peer("receiver")
    assert :ok = :peer.call(receiver, NodeRouterCoordinationPeer, :start_receiver, [])
    assert true == :peer.call(origin, Node, :connect, [receiver_node])
    assert :ok = :peer.call(origin, :global, :sync, [])
    assert :ok = :peer.call(receiver, :global, :sync, [])
    assert :ok = :peer.call(origin, NodeRouterCoordinationPeer, :probe, [receiver_node], 15_000)
  end

  defp peer(suffix) do
    name = String.to_atom("coordination_#{suffix}_#{System.unique_integer([:positive])}")
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, control, peer_node} =
      :peer.start_link(%{
        name: name,
        connection: :standard_io,
        args: [~c"+S", ~c"2", ~c"-setcookie", ~c"zaq_coordination_test" | paths]
      })

    Process.unlink(control)
    on_exit(fn -> :peer.stop(control) end)
    assert {:ok, _} = :peer.call(control, :application, :ensure_all_started, [:elixir])
    {control, peer_node}
  end
end
