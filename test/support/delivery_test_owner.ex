defmodule Zaq.TestSupport.DeliveryTestOwner do
  @moduledoc """
  Routes delivery transport-double observations to the test across supervised tasks.

  Fixture values remain owned by the test process. Task caller ancestry allows
  provider doubles to read those values without global configuration or copying
  process dictionaries into production workers.
  """

  def pid, do: List.last(Process.get(:"$callers", [])) || self()

  def get(key, default \\ nil) do
    {:dictionary, dictionary} = Process.info(pid(), :dictionary)

    case List.keyfind(dictionary, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end
end
