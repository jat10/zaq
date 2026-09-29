defmodule Zaq.Bench.LiveRAG.SmokeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL

  alias Zaq.Bench.LiveRAG.{
    Artifacts,
    Bootstrap,
    Checkpoint,
    Configuration,
    Database,
    Dataset,
    Runner
  }

  alias Zaq.Repo

  setup do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    source_name = "zaq_liverag_smoke_#{suffix}_source"
    target_name = "zaq_liverag_smoke_#{suffix}_restore"

    options =
      Repo.config()
      |> Keyword.delete(:url)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    {:ok, maintenance} = Repo.start_link(Keyword.put(options, :name, nil))
    Process.unlink(maintenance)

    directory = Path.join(System.tmp_dir!(), "zaq_liverag_smoke_#{suffix}")

    on_exit(fn ->
      SQL.query!(maintenance, "DROP DATABASE IF EXISTS #{target_name} WITH (FORCE)", [])
      SQL.query!(maintenance, "DROP DATABASE IF EXISTS #{source_name} WITH (FORCE)", [])
      Supervisor.stop(maintenance)
      File.rm_rf(directory)
    end)

    SQL.query!(maintenance, "CREATE DATABASE #{source_name} TEMPLATE template0", [])
    SQL.query!(maintenance, "CREATE DATABASE #{target_name} TEMPLATE template0", [])

    source_options = Keyword.put(options, :database, source_name)
    target_options = Keyword.put(options, :database, target_name)
    install_vector(source_options)
    install_vector(target_options)

    File.mkdir!(directory)

    {:ok, source_options: source_options, target_options: target_options, directory: directory}
  end

  test "a bounded stubbed run exports and restores exactly the prepared corpus", context do
    source_directory = Path.join(context.directory, "sources")
    write_sources(source_directory)
    assert {:ok, dataset} = Dataset.load(source_directory)

    {:ok, database} = Database.open(Repo.config() |> Keyword.delete(:url), context.source_options)

    try do
      assert :ok = Bootstrap.ensure(database, 2)
      snapshot = snapshot()

      embed = fn text ->
        send(self(), {:embedded, text})

        contender =
          Task.async(fn ->
            Checkpoint.with_lease(
              database,
              dataset.manifest["source_sha256"],
              snapshot.fingerprint,
              fn _ ->
                :unexpected_second_owner
              end
            )
          end)

        assert {:error, :run_busy} = Task.await(contender)
        {:ok, [1.0, 0.0]}
      end

      assert {:ok, %{selected: 1, complete: false}} =
               Runner.ingest(dataset, database, snapshot, limit: 1, pace_ms: 0, embed_fun: embed)

      assert {:ok, %{selected: 1, complete: true}} =
               Runner.ingest(dataset, database, snapshot, limit: 1, pace_ms: 0, embed_fun: embed)

      assert_received {:embedded, "Alpha"}
      assert_received {:embedded, "Beta"}
      assert Runner.inspect(database).documents == %{"completed" => 2}

      export_directory = Path.join(context.directory, "artifact")

      assert {:ok, %{corpus: %{documents: 2, chunks: 2, valid_vectors: true}}} =
               Artifacts.export(
                 database,
                 dataset,
                 source_directory,
                 export_directory,
                 context.source_options
               )

      assert {:ok, %{documents: 2, chunks: 2, valid_vectors: true}} =
               Artifacts.restore_verify(
                 export_directory,
                 context.source_options,
                 context.target_options
               )

      assert {:error, :restore_target_not_empty} =
               Artifacts.restore_verify(
                 export_directory,
                 context.source_options,
                 context.target_options
               )

      File.write!(Path.join([export_directory, "sources", "documents.jsonl"]), "tampered\n", [
        :append
      ])

      assert {:error, :artifact_checksum_mismatch} =
               Artifacts.restore_verify(
                 export_directory,
                 context.source_options,
                 context.target_options
               )
    after
      Database.close(database)
    end
  end

  defp install_vector(options) do
    {:ok, repo} =
      Repo.start_link(
        options
        |> Keyword.put(:name, nil)
        |> Keyword.put(:pool, DBConnection.ConnectionPool)
      )

    SQL.query!(repo, "CREATE EXTENSION vector", [])
    Supervisor.stop(repo)
  end

  defp write_sources(directory) do
    File.mkdir!(directory)

    pin =
      Application.app_dir(:zaq, "priv/bench/liverag/pin.json") |> File.read!() |> Jason.decode!()

    files = %{
      "documents.jsonl" => [
        %{"doc_id" => "beta", "content" => "Beta"},
        %{"doc_id" => "alpha", "content" => "Alpha"}
      ],
      "aliases.jsonl" => [
        %{"source_doc_id" => "alpha", "doc_id" => "alpha"},
        %{"source_doc_id" => "beta", "doc_id" => "beta"}
      ],
      "mappings.jsonl" => [
        %{
          "question_id" => 0,
          "source_doc_ids" => ["alpha", "beta"],
          "doc_ids" => ["alpha", "beta"]
        }
      ]
    }

    hashes =
      Map.new(files, fn {name, rows} ->
        bytes = Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
        File.write!(Path.join(directory, name), bytes)
        {name, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
      end)

    manifest =
      pin
      |> Map.put("extractor_version", 1)
      |> Map.put("counts", %{"documents" => 2, "aliases" => 2, "mappings" => 1})
      |> Map.put("sha256", hashes)

    File.write!(Path.join(directory, "manifest.json"), Jason.encode!(manifest))
  end

  defp snapshot do
    %Configuration{
      embedding: %{dimension: 2, model: "stub", chunk_min_tokens: 1, chunk_max_tokens: 100},
      provider: %{endpoint: "http://localhost"},
      resolved_credential: %{auth_kind: "none", authentication: %{}},
      fingerprint: String.duplicate("b", 64)
    }
  end
end
