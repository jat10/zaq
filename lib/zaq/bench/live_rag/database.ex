defmodule Zaq.Bench.LiveRAG.Database do
  @moduledoc """
  Owns the standalone source and corpus repository pools for corpus preparation.

  Both pools use `Zaq.Repo`'s existing schemas. Process-local dynamic repository
  selection keeps System and Engine reads on the source pool while later corpus
  writes target the separate destination pool. Callers must close the pools.
  """

  alias Zaq.Repo

  @enforce_keys [:source, :corpus]
  @derive {Inspect, only: []}
  defstruct [:source, :corpus]

  @type t :: %__MODULE__{source: pid(), corpus: pid()}

  @doc "Starts separate pools and refuses two connections to the same database."
  @spec open(keyword(), keyword()) :: {:ok, t()} | {:error, atom()}
  def open(source_options, corpus_options)
      when is_list(source_options) and is_list(corpus_options) do
    case start_pool(source_options) do
      {:ok, source} -> open_corpus(source, corpus_options)
      {:error, _} -> {:error, :source_connection_failed}
    end
  end

  @doc "Stops both standalone pools."
  @spec close(t()) :: :ok
  def close(%__MODULE__{source: source, corpus: corpus}) do
    Supervisor.stop(corpus)
    Supervisor.stop(source)
    :ok
  end

  @doc "Runs a function using the source pool only in the current process."
  @spec with_source(%{source: pid() | atom()}, (-> result)) :: result when result: var
  def with_source(%{source: source}, fun) when is_function(fun, 0), do: with_repo(source, fun)

  @doc "Runs a function using the corpus pool only in the current process."
  @spec with_corpus(%{corpus: pid() | atom()}, (-> result)) :: result when result: var
  def with_corpus(%{corpus: corpus}, fun) when is_function(fun, 0), do: with_repo(corpus, fun)

  defp open_corpus(source, corpus_options) do
    case start_pool(corpus_options) do
      {:ok, corpus} ->
        check_distinct(source, corpus)

      {:error, _} ->
        Supervisor.stop(source)
        {:error, :corpus_connection_failed}
    end
  end

  defp check_distinct(source, corpus) do
    source_identity = with_repo(source, &database_identity/0)
    corpus_identity = with_repo(corpus, &database_identity/0)

    case {source_identity, corpus_identity} do
      {{:ok, identity}, {:ok, identity}} ->
        Supervisor.stop(corpus)
        Supervisor.stop(source)
        {:error, :database_alias}

      {{:ok, _}, {:ok, _}} ->
        {:ok, %__MODULE__{source: source, corpus: corpus}}

      _ ->
        Supervisor.stop(corpus)
        Supervisor.stop(source)
        {:error, :database_identity_failed}
    end
  end

  defp database_identity do
    case Repo.query(
           "SELECT current_database(), current_setting('port'), inet_server_addr()::text",
           [],
           log: false
         ) do
      {:ok, %{rows: [identity]}} -> {:ok, identity}
      {:error, _} -> {:error, :database_identity_failed}
    end
  end

  defp start_pool(options) do
    options =
      options
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:show_sensitive_data_on_connection_error, false)

    Repo.start_link(options)
  end

  defp with_repo(repo, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
