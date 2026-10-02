defmodule Zaq.Bench.LiveRAG.Dataset do
  @moduledoc """
  Loads the pinned LiveRAG supporting corpus extracted under `priv/bench/liverag`.

  This module reads only derived, checksum-verified source records and mappings.
  Corpus database persistence belongs to the later preparation runner.
  """

  @files %{
    documents: "documents.jsonl",
    aliases: "aliases.jsonl",
    mappings: "mappings.jsonl"
  }

  @type corpus :: %{
          documents: [map()],
          aliases: [map()],
          mappings: [map()],
          manifest: map()
        }

  @doc "Loads the extracted corpus after checking each artifact against its manifest digest."
  @spec load(Path.t()) :: {:ok, corpus()} | {:error, term()}
  def load(directory) when is_binary(directory) do
    with {:ok, manifest} <- read_json(Path.join(directory, "manifest.json")),
         :ok <- verify_pin(manifest),
         {:ok, documents} <- read_lines(directory, manifest, :documents),
         {:ok, aliases} <- read_lines(directory, manifest, :aliases),
         {:ok, mappings} <- read_lines(directory, manifest, :mappings),
         :ok <- validate_counts(manifest, documents, aliases, mappings),
         :ok <- validate_references(documents, aliases, mappings) do
      {:ok, %{documents: documents, aliases: aliases, mappings: mappings, manifest: manifest}}
    end
  end

  defp verify_pin(manifest) do
    pin_path = Application.app_dir(:zaq, "priv/bench/liverag/pin.json")

    with {:ok, pin} <- read_json(pin_path) do
      verify_pin_fields(pin, manifest)
    end
  end

  defp verify_pin_fields(pin, manifest) do
    if manifest["extractor_version"] == 1 and
         Enum.all?(pin, fn {key, value} -> manifest[key] == value end),
       do: :ok,
       else: {:error, :source_pin_mismatch}
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value}
    else
      {:ok, _} -> {:error, {:invalid_json, path}}
      {:error, reason} -> {:error, {:invalid_json, path, reason}}
    end
  end

  defp read_lines(directory, manifest, key) do
    name = Map.fetch!(@files, key)
    path = Path.join(directory, name)

    with {:ok, bytes} <- File.read(path),
         :ok <- verify_hash(bytes, manifest, name) do
      decode_lines(bytes, name)
    end
  end

  defp verify_hash(bytes, manifest, name) do
    expected = get_in(manifest, ["sha256", name])
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if is_binary(expected) and expected == actual,
      do: :ok,
      else: {:error, {:checksum_mismatch, name}}
  end

  defp decode_lines(bytes, name) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, records} ->
      case Jason.decode(line) do
        {:ok, record} when is_map(record) -> {:cont, {:ok, [record | records]}}
        _ -> {:halt, {:error, {:invalid_record, name}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp validate_counts(manifest, documents, aliases, mappings) do
    expected = manifest["counts"]

    actual = %{
      "documents" => length(documents),
      "aliases" => length(aliases),
      "mappings" => length(mappings)
    }

    if expected == actual, do: :ok, else: {:error, :count_mismatch}
  end

  defp validate_references(documents, aliases, mappings) do
    if valid_documents?(documents) and valid_aliases?(documents, aliases) and
         valid_mappings?(aliases, mappings),
       do: :ok,
       else: {:error, :invalid_reference}
  end

  defp valid_documents?(documents) do
    Enum.all?(documents, fn document ->
      is_binary(document["doc_id"]) and document["doc_id"] != "" and
        is_binary(document["content"]) and String.trim(document["content"]) != ""
    end) and unique_by?(documents, "doc_id")
  end

  defp valid_aliases?(documents, aliases) do
    ids = MapSet.new(documents, & &1["doc_id"])

    Enum.all?(aliases, fn alias_record ->
      is_binary(alias_record["source_doc_id"]) and alias_record["source_doc_id"] != "" and
        MapSet.member?(ids, alias_record["doc_id"])
    end) and unique_by?(aliases, "source_doc_id")
  end

  defp valid_mappings?(aliases, mappings) do
    aliases_by_source = Map.new(aliases, &{&1["source_doc_id"], &1["doc_id"]})

    Enum.all?(mappings, &valid_mapping?(&1, aliases_by_source)) and
      unique_by?(mappings, "question_id")
  end

  defp valid_mapping?(mapping, aliases_by_source) do
    sources = mapping["source_doc_ids"]
    ids = mapping["doc_ids"]

    is_integer(mapping["question_id"]) and mapping["question_id"] >= 0 and
      is_list(sources) and sources != [] and is_list(ids) and
      Enum.all?(sources, &Map.has_key?(aliases_by_source, &1)) and
      ids == Enum.uniq(Enum.map(sources, &aliases_by_source[&1]))
  end

  defp unique_by?(records, key) do
    records |> MapSet.new(& &1[key]) |> MapSet.size() == length(records)
  end
end
