defmodule Zaq.Channels.ConnectorLifecycleLockTest do
  use ExUnit.Case, async: true
  alias Zaq.ConnectorConfig.LifecycleLock

  test "a shared RPC requester cannot release the root operation's lock" do
    id = System.unique_integer([:positive])
    observer = self()

    root =
      Task.async(fn ->
        LifecycleLock.with_lock(id, fn ->
          token = LifecycleLock.owner()

          callback =
            Task.async(fn ->
              LifecycleLock.with_owner(token, fn ->
                LifecycleLock.with_lock(id, fn -> send(observer, :callback_completed) end)
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
    blocked = Task.async(fn -> LifecycleLock.with_lock(id, fn -> :acquired end) end)
    assert Task.yield(blocked, 30) == nil
    send(root.pid, :finish)
    assert :ok = Task.await(root)
    assert :acquired = Task.await(blocked)
  end

  test "nested calls and exceptions release only their own scope" do
    id = System.unique_integer([:positive])

    assert_raise RuntimeError, fn ->
      LifecycleLock.with_lock(id, fn ->
        LifecycleLock.with_lock(id, fn -> raise "abort" end)
      end)
    end

    assert LifecycleLock.owner() == nil
    assert :released = LifecycleLock.with_lock(id, fn -> :released end)
  end

  test "caller death releases a held connector lock" do
    id = System.unique_integer([:positive])
    observer = self()

    holder =
      spawn(fn ->
        LifecycleLock.with_lock(id, fn ->
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
    assert :released = LifecycleLock.with_lock(id, fn -> :released end)
  end
end
