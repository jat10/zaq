defmodule Zaq.Bench.LiveRAG.Artifacts do
  @moduledoc """
  Creates and verifies a secret-free, restore-tested corpus artifact directory.

  PostgreSQL utilities receive credentials only through their environment.
  Every copied input and the custom-format dump are checksummed before a
  manifest is published. Restore accepts only an empty, isolated target.
  """

  alias Zaq.Bench.LiveRAG.{CorpusIntegrity, Database, Dataset}
  alias Zaq.Repo

  @source_files ~w(documents.jsonl aliases.jsonl mappings.jsonl manifest.json)

  @doc "Exports a verified complete corpus into a new directory atomically."
  @spec export(map(), map(), Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def export(database, dataset, source_directory, destination, connection_options) do
    with {:ok, ^dataset} <- Dataset.load(source_directory),
         {:ok, fingerprint} <- CorpusIntegrity.complete(database, dataset),
         :ok <- destination_available(destination) do
      temporary = destination <> ".partial-" <> Ecto.UUID.generate()

      try do
        File.mkdir!(temporary)
        File.mkdir!(Path.join(temporary, "sources"))
        copy_sources!(source_directory, temporary)

        case postgres_command(
               "pg_dump",
               dump_args(temporary, connection_options),
               connection_options
             ) do
          :ok ->
            manifest = build_manifest(temporary, dataset.manifest, fingerprint)

            File.write!(
              Path.join(temporary, "manifest.json"),
              Jason.encode!(manifest, pretty: true) <> "\n"
            )

            File.rename!(temporary, destination)
            {:ok, manifest}

          {:error, _} ->
            {:error, :dump_failed}
        end
      after
        File.rm_rf(temporary)
      end
    end
  end

  @doc "Restores an artifact into an empty database and compares rows, indexes and sequences."
  @spec restore_verify(Path.t(), keyword(), keyword()) :: {:ok, map()} | {:error, atom()}
  def restore_verify(directory, source_options, target_options) do
    with {:ok, manifest} <- read_manifest(directory),
         :ok <- verify_files(directory, manifest),
         {:ok, dataset} <- Dataset.load(Path.join(directory, "sources")),
         true <- manifest["source"] == source_identity(dataset.manifest),
         true <- get_in(manifest, ["corpus", "input_sha256"]) == dataset.manifest["source_sha256"],
         {:ok, database} <- Database.open(source_options, target_options) do
      try do
        with :ok <- empty_target(database),
             :ok <-
               postgres_command(
                 "pg_restore",
                 restore_args(directory, target_options),
                 target_options
               ),
             :ok <- restored_tables(database),
             actual <- CorpusIntegrity.fingerprint(database),
             true <- same_fingerprint?(actual, manifest["corpus"]) do
          {:ok, actual}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :restore_verification_failed}
        end
      after
        Database.close(database)
      end
    end
  end

  defp destination_available(destination) do
    case File.lstat(destination) do
      {:ok, _} ->
        {:error, :destination_unavailable}

      {:error, :enoent} ->
        if(File.dir?(Path.dirname(destination)),
          do: :ok,
          else: {:error, :destination_unavailable}
        )

      {:error, _} ->
        {:error, :destination_unavailable}
    end
  end

  defp copy_sources!(source_directory, temporary) do
    Enum.each(@source_files, fn name ->
      File.cp!(Path.join(source_directory, name), Path.join([temporary, "sources", name]))
    end)
  end

  defp build_manifest(directory, source, fingerprint) do
    files = ["corpus.dump" | Enum.map(@source_files, &"sources/#{&1}")]

    %{
      version: 1,
      source: source_identity(source),
      corpus: fingerprint,
      sha256: Map.new(files, &{&1, file_sha256(Path.join(directory, &1))})
    }
  end

  defp source_identity(source),
    do: Map.take(source, ["dataset", "revision", "filename", "source_sha256", "source_size"])

  defp read_manifest(directory) do
    with {:ok, bytes} <- File.read(Path.join(directory, "manifest.json")),
         {:ok, %{"version" => 1} = manifest} <- Jason.decode(bytes) do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_artifact_manifest}
    end
  end

  defp verify_files(directory, %{"sha256" => hashes}) when is_map(hashes) do
    expected = ["corpus.dump" | Enum.map(@source_files, &"sources/#{&1}")]
    names_match? = Enum.sort(Map.keys(hashes)) == Enum.sort(expected)
    content_matches? = Enum.all?(expected, &file_matches?(directory, &1, hashes[&1]))

    if names_match? and content_matches?, do: :ok, else: {:error, :artifact_checksum_mismatch}
  end

  defp verify_files(_, _), do: {:error, :invalid_artifact_manifest}

  defp file_matches?(directory, name, expected) do
    path = Path.join(directory, name)
    File.regular?(path) and file_sha256(path) == expected
  end

  defp empty_target(database) do
    Database.with_corpus(database, fn ->
      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND c.relname NOT LIKE 'pg_%'",
          [],
          log: false
        )

      if rows == [], do: :ok, else: {:error, :restore_target_not_empty}
    end)
  end

  defp restored_tables(database) do
    Database.with_corpus(database, fn ->
      {:ok, %{rows: rows}} =
        Repo.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public'", [], log: false)

      if Enum.sort(Enum.map(rows, &hd/1)) == Enum.sort(~w(documents chunks)),
        do: :ok,
        else: {:error, :unexpected_restored_schema}
    end)
  end

  defp same_fingerprint?(actual, expected) when is_map(expected) do
    Enum.all?(
      ~w(documents chunks dimension valid_vectors rows_sha256 indexes_sha256 sequences_sha256),
      fn key ->
        Map.get(actual, String.to_existing_atom(key)) == expected[key]
      end
    )
  end

  defp same_fingerprint?(_, _), do: false

  defp dump_args(directory, options) do
    [
      "--format=custom",
      "--no-owner",
      "--no-privileges",
      "--table=public.documents",
      "--table=public.chunks",
      "--file=#{Path.join(directory, "corpus.dump")}"
    ] ++ connection_args(options)
  end

  defp restore_args(directory, options) do
    [
      "--exit-on-error",
      "--single-transaction",
      "--no-owner",
      "--no-privileges",
      Path.join(directory, "corpus.dump")
    ] ++ connection_args(options)
  end

  defp postgres_command(name, args, options) do
    case System.find_executable(name) do
      nil -> {:error, :postgres_tool_missing}
      executable -> run_postgres(executable, args, options)
    end
  end

  defp run_postgres(executable, args, options) do
    info = connection_info(options)

    {_output, status} =
      System.cmd(executable, args,
        stderr_to_stdout: true,
        env: [
          {"PGPASSWORD", info.password || ""},
          {"PGCONNECT_TIMEOUT", "10"},
          {"PGSSLMODE", info.sslmode}
        ]
      )

    if status == 0, do: :ok, else: {:error, :postgres_command_failed}
  end

  defp connection_args(options) do
    info = connection_info(options)

    [
      "--dbname=#{info.database}",
      "--host=#{info.host}",
      "--port=#{info.port}",
      "--username=#{info.username}",
      "--no-password"
    ]
  end

  defp connection_info(options) do
    case options[:url] do
      nil -> connection_info_from_options(options)
      url -> connection_info_from_url(url)
    end
  end

  defp connection_info_from_options(options) do
    %{
      database: options[:database],
      host: options[:hostname] || "localhost",
      port: options[:port] || 5432,
      username: options[:username] || System.get_env("USER"),
      password: options[:password],
      sslmode: if(options[:ssl], do: "require", else: "prefer")
    }
  end

  defp connection_info_from_url(url) do
    uri = URI.parse(url)
    {username, password} = split_userinfo(uri.userinfo)
    query = URI.decode_query(uri.query || "")

    %{
      database: URI.decode(String.trim_leading(uri.path || "", "/")),
      host: uri.host || "localhost",
      port: uri.port || 5432,
      username: username,
      password: password,
      sslmode: Map.get(query, "sslmode", "prefer")
    }
  end

  defp split_userinfo(nil), do: {System.get_env("USER"), nil}

  defp split_userinfo(value) do
    case String.split(value, ":", parts: 2) do
      [username, password] -> {URI.decode(username), URI.decode(password)}
      [username] -> {URI.decode(username), nil}
    end
  end

  defp file_sha256(path) do
    File.stream!(path, [], 64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
