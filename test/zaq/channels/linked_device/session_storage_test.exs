defmodule Zaq.Channels.LinkedDevice.SessionStorageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.LinkedDevice.SessionStorage

  @table :zaq_linked_device_sessions

  setup do
    scope = {System.unique_integer([:positive]), 1, Ecto.UUID.generate()}
    on_exit(fn -> SessionStorage.execute(scope, %{op: :clear}) end)
    %{scope: scope}
  end

  test "the table and schema are RAM-only and node-local" do
    assert :mnesia.table_info(@table, :storage_type) == :ram_copies
    assert :mnesia.table_info(@table, :local_content)
    assert :mnesia.table_info(@table, :disc_copies) == []
    assert :mnesia.table_info(@table, :disc_only_copies) == []
    refute :mnesia.system_info(:use_dir)
  end

  property "records round-trip independently by namespace and profile", %{scope: scope} do
    other = put_elem(scope, 2, Ecto.UUID.generate())
    on_exit(fn -> SessionStorage.execute(other, %{op: :clear}) end)

    check all(value <- binary(max_length: 4096), max_runs: 25) do
      assert :ok = put(scope, "session", "peer", value)
      assert :ok = put(scope, "sender_key", "peer", "group")
      assert :ok = put(other, "session", "peer", "other")
      assert {:ok, ^value} = get(scope, "session", "peer")
      assert {:ok, "group"} = get(scope, "sender_key", "peer")
      assert {:ok, "other"} = get(other, "session", "peer")
      assert :ok = SessionStorage.execute(scope, %{op: :clear})
      assert :error = get(scope, "session", "peer")
      assert {:ok, "other"} = get(other, "session", "peer")
    end
  end

  test "concurrent callbacks preserve records after the writer processes exit", %{scope: scope} do
    results =
      Task.async_stream(1..30, fn n -> put(scope, "session", to_string(n), "value") end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, keys} = SessionStorage.execute(scope, %{op: :list_keys, namespace: "session"})
    assert Enum.sort(keys) == Enum.sort(Enum.map(1..30, &to_string/1))
    assert :ok = SessionStorage.execute(scope, %{op: :delete, namespace: "session", key: "1"})
    assert :error = get(scope, "session", "1")
    assert {:ok, "value"} = get(scope, "session", "2")
  end

  test "snapshot seeding is atomic and never overwrites advanced or deleted sessions", %{
    scope: scope
  } do
    records = %{{"session", "peer"} => "initial", {"sender_key", "group"} => "key"}
    assert :ok = SessionStorage.seed(scope, records)
    assert :ok = put(scope, "session", "peer", "advanced")

    assert :ok =
             SessionStorage.execute(scope, %{op: :delete, namespace: "sender_key", key: "group"})

    assert :ok = SessionStorage.seed(scope, records)
    assert {:ok, "advanced"} = get(scope, "session", "peer")
    assert :error = get(scope, "sender_key", "group")
  end

  test "capacity failures preserve existing state and deletion releases capacity", %{scope: scope} do
    value = String.duplicate("v", 1024 * 1024)
    for n <- 1..15, do: assert(:ok = put(scope, "session", to_string(n), value))
    assert {:error, :storage_full} = put(scope, "session", "overflow", value)
    assert :error = get(scope, "session", "overflow")
    assert {:ok, ^value} = get(scope, "session", "1")
    assert :ok = SessionStorage.execute(scope, %{op: :delete, namespace: "session", key: "1"})
    assert :ok = put(scope, "session", "replacement", value)
    assert {:error, :invalid_request} = put(scope, "session", "large", value <> "v")
  end

  test "late snapshots cannot overwrite a running connection or restore cleared keys", %{
    scope: scope
  } do
    assert :ok = put(scope, "session", "peer", "running")
    snapshot = %{{"session", "peer"} => "old"}
    assert :ok = SessionStorage.seed(scope, snapshot)
    assert {:ok, "running"} = get(scope, "session", "peer")
    assert :ok = SessionStorage.execute(scope, %{op: :clear})
    assert :ok = SessionStorage.seed(scope, snapshot)
    assert :error = get(scope, "session", "peer")
  end

  test "an oversized snapshot leaves no partial records or seed marker", %{scope: scope} do
    records = Map.new(1..16, &{{"session", to_string(&1)}, String.duplicate("s", 1024 * 1024)})
    assert {:error, :storage_full} = SessionStorage.seed(scope, records)
    assert {:ok, []} = SessionStorage.execute(scope, %{op: :list_keys, namespace: "session"})
    assert :ok = SessionStorage.seed(scope, %{{"session", "peer"} => "valid"})
    assert {:ok, "valid"} = get(scope, "session", "peer")
  end

  test "an unavailable store fails closed and Mnesia restart loses state without writing files" do
    directory = Path.join(System.tmp_dir!(), "zaq-mnesia-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(directory) end)
    ebin = SessionStorage |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    alias Zaq.Channels.LinkedDevice.SessionStorage, as: Store
    Application.put_env(:mnesia, :schema_location, :ram)
    Application.put_env(:mnesia, :dir, String.to_charlist(#{inspect(directory)}))
    {:ok, _} = Application.ensure_all_started(:mnesia)
    {:ok, owner} = Store.start_link([])
    scope = {1, 2, "account"}
    :ok = Store.execute(scope, %{op: :put, namespace: "session", key: "peer", value: "state"})
    GenServer.stop(owner)
    {:ok, owner} = Store.start_link([])
    {:ok, "state"} = Store.execute(scope, %{op: :get, namespace: "session", key: "peer"})
    GenServer.stop(owner)
    :stopped = :mnesia.stop()
    {:error, :storage_unavailable} = Store.execute(scope, %{op: :get, namespace: "session", key: "peer"})
    :ok = :mnesia.start()
    {:ok, _} = Store.start_link([])
    :error = Store.execute(scope, %{op: :get, namespace: "session", key: "peer"})
    false = :mnesia.system_info(:use_dir)
    false = File.exists?(#{inspect(directory)})
    IO.puts("RAM_RESTART_OK")
    """

    {output, status} =
      System.cmd("elixir", ["--erl", "+S 2:2", "-pa", ebin, "-e", script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "RAM_RESTART_OK"
  end

  defp put(scope, namespace, key, value),
    do: SessionStorage.execute(scope, %{op: :put, namespace: namespace, key: key, value: value})

  defp get(scope, namespace, key),
    do: SessionStorage.execute(scope, %{op: :get, namespace: namespace, key: key})
end
