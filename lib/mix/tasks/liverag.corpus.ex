defmodule Mix.Tasks.Liverag.Corpus do
  use Mix.Task

  @shortdoc "Prepare a bounded LiveRAG supporting corpus in an isolated database"
  @moduledoc """
  Operator commands for the pinned LiveRAG supporting corpus.

      mix liverag.corpus extract
      mix liverag.corpus ingest 10 --corpus-url POSTGRES_URL --person-id ID
      mix liverag.corpus inspect --corpus-url POSTGRES_URL
      mix liverag.corpus retry 12,13 --corpus-url POSTGRES_URL --person-id ID
      mix liverag.corpus export --corpus-url POSTGRES_URL --output-dir PATH
      mix liverag.corpus verify --corpus-url POSTGRES_URL --artifact-dir PATH --restore-url EMPTY_POSTGRES_URL

  `ingest` never defaults to the full corpus. `retry` names failed checkpoint
  chunk IDs explicitly. The source database defaults to the configured ZAQ Repo;
  `--source-url` overrides it. Generated extraction files default to
  `priv/bench/liverag/data`.
  """

  alias Zaq.Bench.LiveRAG.{
    Artifacts,
    Bootstrap,
    Configuration,
    Database,
    Dataset,
    Extractor,
    Runner
  }

  alias Zaq.Repo

  @switches [
    corpus_url: :string,
    source_url: :string,
    person_id: :integer,
    data_dir: :string,
    max_requests: :integer,
    deadline_ms: :integer,
    pace_ms: :integer,
    attempts: :integer,
    output_dir: :string,
    artifact_dir: :string,
    restore_url: :string
  ]

  @impl true
  def run(args) do
    {opts, command, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("Invalid LiveRAG corpus option")
    Mix.Task.run("app.config")
    start_dependencies(command)

    if command == ["extract"] do
      directory = opts[:data_dir] || Application.app_dir(:zaq, "priv/bench/liverag/data")

      directory
      |> Extractor.extract!()
      |> Map.fetch!("counts")
      |> print_json()
    else
      corpus_url = opts[:corpus_url] || Mix.raise("--corpus-url is required")
      source_options = pool_options(opts[:source_url])
      corpus_options = pool_options(corpus_url)

      if command == ["verify"] do
        verify_artifact(opts, corpus_options)
      else
        open_and_dispatch(command, opts, source_options, corpus_options)
      end
    end
  end

  defp start_dependencies(["extract"]) do
    {:ok, _} = Application.ensure_all_started(:explorer)
    {:ok, _} = Application.ensure_all_started(:req)
  end

  defp start_dependencies(_) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:req)
  end

  defp open_and_dispatch(command, opts, source_options, corpus_options) do
    case Database.open(source_options, corpus_options) do
      {:ok, database} ->
        try do
          dispatch(command, database, opts)
        after
          Database.close(database)
        end

      {:error, reason} ->
        Mix.raise("Cannot open isolated corpus pools: #{reason}")
    end
  end

  defp dispatch(["inspect"], database, _opts) do
    database |> Runner.inspect() |> print_json()
  end

  defp dispatch(["ingest", count], database, opts) do
    with {limit, ""} <- Integer.parse(count),
         {:ok, dataset} <- load_dataset(opts),
         {:ok, snapshot} <- load_snapshot(database, opts),
         :ok <- Bootstrap.ensure(database, snapshot.embedding.dimension),
         {:ok, report} <- Runner.ingest(dataset, database, snapshot, runner_opts(opts, limit)) do
      print_json(report)
      exit_for_report(report)
    else
      {:error, :run_busy} ->
        Mix.raise("LiveRAG corpus is busy")

      _ ->
        Mix.raise(
          "LiveRAG ingest failed; inspect source configuration, corpus schema, and input files"
        )
    end
  end

  defp dispatch(["retry", list], database, opts) do
    with {:ok, ids} <- parse_ids(list),
         {:ok, dataset} <- load_dataset(opts),
         {:ok, snapshot} <- load_snapshot(database, opts),
         {:ok, retried} <-
           Runner.retry(
             database,
             dataset.manifest["source_sha256"],
             snapshot.fingerprint,
             ids,
             snapshot.contract
           ) do
      print_json(%{retried: retried})
    else
      {:error, :run_busy} -> Mix.raise("LiveRAG corpus is busy")
      _ -> Mix.raise("LiveRAG retry failed; use explicit failed chunk IDs from inspect")
    end
  end

  defp dispatch(["export"], database, opts) do
    with directory when is_binary(directory) <- opts[:output_dir],
         {:ok, dataset} <- load_dataset(opts),
         {:ok, manifest} <-
           Artifacts.export(
             database,
             dataset,
             opts[:data_dir] || Application.app_dir(:zaq, "priv/bench/liverag/data"),
             directory,
             pool_options(opts[:corpus_url])
           ) do
      print_json(manifest)
    else
      _ -> Mix.raise("LiveRAG export refused; inspect corpus completeness and output directory")
    end
  end

  defp dispatch(_, _, _),
    do: Mix.raise("Use: ingest COUNT | inspect | retry ID[,ID] | export | verify")

  defp verify_artifact(opts, corpus_options) do
    with directory when is_binary(directory) <- opts[:artifact_dir],
         target_url when is_binary(target_url) <- opts[:restore_url],
         {:ok, report} <-
           Artifacts.restore_verify(directory, corpus_options, pool_options(target_url)) do
      print_json(report)
    else
      _ -> Mix.raise("LiveRAG restore verification failed; use an empty isolated target")
    end
  end

  defp pool_options(nil), do: Repo.config()
  defp pool_options(url), do: Keyword.put(Repo.config(), :url, url)

  defp load_dataset(opts) do
    directory = opts[:data_dir] || Application.app_dir(:zaq, "priv/bench/liverag/data")
    Dataset.load(directory)
  end

  defp load_snapshot(database, opts) do
    case opts[:person_id] do
      id when is_integer(id) and id > 0 -> Configuration.load(database, %{person: %{id: id}})
      _ -> {:error, :person_id_required}
    end
  end

  defp runner_opts(opts, limit) do
    [limit: limit]
    |> put_option(opts, :max_requests)
    |> put_option(opts, :deadline_ms)
    |> put_option(opts, :pace_ms)
    |> put_option(opts, :attempts)
  end

  defp put_option(acc, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(acc, key, value)
      :error -> acc
    end
  end

  defp parse_ids(list) do
    ids = String.split(list, ",")

    parsed =
      Enum.map(ids, fn value ->
        case Integer.parse(value) do
          {id, ""} when id > 0 -> id
          _ -> nil
        end
      end)

    if parsed != [] and Enum.all?(parsed, &is_integer/1) and Enum.uniq(parsed) == parsed,
      do: {:ok, parsed},
      else: {:error, :invalid_retry_ids}
  end

  defp print_json(value), do: Mix.shell().info(Jason.encode!(value))

  defp exit_for_report(%{complete: true}), do: :ok
  defp exit_for_report(%{stopped: :run_busy}), do: Mix.raise("LiveRAG corpus is busy")

  defp exit_for_report(%{failed: failed}) when failed > 0,
    do: Mix.raise("LiveRAG corpus has failed chunks")

  defp exit_for_report(_), do: Mix.raise("LiveRAG corpus remains incomplete")
end
