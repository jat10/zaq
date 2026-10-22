defmodule Zaq.Channels.ConnectorLifecycleLockTest do
  import Zaq.TestSupport.NodeRouterCoordination, only: [coordinate: 2]
  use ExUnit.Case, async: true
  alias Zaq.NodeRouter.Coordination

  test "a shared RPC requester cannot release the root operation's lock" do
    id = System.unique_integer([:positive])
    observer = self()

    root =
      Task.async(fn ->
        coordinate({:connector_lifecycle, id}, fn ->
          token = Coordination.context()

          callback =
            Task.async(fn ->
              Coordination.run(token, fn ->
                coordinate({:connector_lifecycle, id}, fn ->
                  send(observer, :callback_completed)
                end)
              end)
            end)

          Task.await(callback)
          send(observer, :root_still_owns_lock)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :callback_completed
    assert_receive :root_still_owns_lock

    blocked =
      Task.async(fn ->
        coordinate({:connector_lifecycle, id}, fn -> :acquired end)
      end)

    assert Task.yield(blocked, 30) == nil
    send(root.pid, :finish)
    assert :ok = Task.await(root)
    assert :acquired = Task.await(blocked)
  end

  test "nested calls and exceptions release only their own scope" do
    id = System.unique_integer([:positive])

    assert_raise RuntimeError, fn ->
      coordinate({:connector_lifecycle, id}, fn ->
        coordinate({:connector_lifecycle, id}, fn -> raise "abort" end)
      end)
    end

    assert Coordination.context() == %{}

    assert :released =
             coordinate({:connector_lifecycle, id}, fn -> :released end)
  end

  test "caller death releases a held connector lock" do
    id = System.unique_integer([:positive])
    observer = self()

    holder =
      spawn(fn ->
        coordinate({:connector_lifecycle, id}, fn ->
          send(observer, :held)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :held
    monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}

    assert :released =
             coordinate({:connector_lifecycle, id}, fn -> :released end)
  end
end
