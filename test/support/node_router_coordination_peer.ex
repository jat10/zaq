defmodule Zaq.TestSupport.NodeRouterCoordinationPeer do
  import Zaq.TestSupport.NodeRouterCoordination, only: [coordinate: 2]
  @moduledoc false
  import ExUnit.Assertions
  alias Zaq.{Event, NodeRouter}

  def start_receiver do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    true = Process.register(pid, ZaqWeb.Endpoint)
    :ok
  end

  def probe(receiver_node) do
    resource = {__MODULE__, make_ref()}
    observer = self()
    assert NodeRouter.find_node(ZaqWeb.Endpoint) == receiver_node

    root =
      spawn(fn ->
        coordinate(resource, fn ->
          NodeRouter.dispatch(event(:receive_work, [observer, resource]))
        end)
      end)

    assert_receive {:receiver_held, receiver}, 5_000
    assert node(receiver) == receiver_node
    monitor = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, 5_000

    contender =
      Task.async(fn ->
        send(observer, :contending)

        coordinate(resource, fn ->
          send(observer, :entered)
          :entered
        end)
      end)

    try do
      assert_receive :contending, 5_000
      refute_receive :entered, 100
      assert :independent = coordinate(make_ref(), fn -> :independent end)
      send(receiver, :finish)
      assert Task.await(contender, 5_000) == :entered
      :ok
    after
      send(receiver, :finish)
      Task.shutdown(contender, :brutal_kill)
    end
  end

  def receive_work(observer, resource) do
    assert NodeRouter.coordinated?(resource)
    assert NodeRouter.dispatch(event(:nested, [resource])).response == :nested
    send(observer, {:receiver_held, self()})
    receive do: (:finish -> :ok)
  end

  def nested(resource) do
    coordinate(resource, fn -> :nested end)
  end

  defp event(function, args) do
    Event.new(%{module: __MODULE__, function: function, args: args}, :bo,
      opts: [action: :invoke, confidential: true]
    )
  end
end
