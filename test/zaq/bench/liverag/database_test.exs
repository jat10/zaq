defmodule Zaq.Bench.LiveRAG.DatabaseTest do
  use ExUnit.Case, async: false

  alias Zaq.Bench.LiveRAG.Database
  alias Zaq.Repo

  test "restores the calling process's repository after an exception" do
    original = Repo.get_dynamic_repo()

    assert_raise RuntimeError, "interrupted", fn ->
      Database.with_source(%{source: self()}, fn ->
        assert Repo.get_dynamic_repo() == self()
        raise "interrupted"
      end)
    end

    assert Repo.get_dynamic_repo() == original
  end

  @tag :integration
  test "refuses source and corpus pools that point at the same database" do
    assert {:error, :database_alias} = Database.open([], [])
  end

  @tag :integration
  test "routes source and corpus work to separate connection pools" do
    options = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1]
    source = start_supervised!(%{id: :source_repo, start: {Repo, :start_link, [options]}})
    corpus = start_supervised!(%{id: :corpus_repo, start: {Repo, :start_link, [options]}})

    database = %{source: source, corpus: corpus}

    source_backend =
      Database.with_source(database, fn ->
        assert Repo.get_dynamic_repo() == source
        {:ok, %{rows: [[backend]]}} = Repo.query("SELECT pg_backend_pid()", [], log: false)
        backend
      end)

    corpus_backend =
      Database.with_corpus(database, fn ->
        assert Repo.get_dynamic_repo() == corpus
        {:ok, %{rows: [[backend]]}} = Repo.query("SELECT pg_backend_pid()", [], log: false)
        backend
      end)

    refute source_backend == corpus_backend
    assert Repo.get_dynamic_repo() == Repo
  end
end
