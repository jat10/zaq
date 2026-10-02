defmodule Zaq.Bench.LiveRAG.Extractor do
  @moduledoc """
  Extracts the pinned LiveRAG supporting corpus from Parquet into verified JSONL.

  This offline operation neither opens a ZAQ database nor starts ingestion. The
  source archive and derived files remain under the ignored benchmark data path.
  """

  @output_files [
    documents: "documents.jsonl",
    aliases: "aliases.jsonl",
    mappings: "mappings.jsonl"
  ]

  @doc "Reads the pinned Parquet file and writes deterministic source artifacts."
  @spec extract!(Path.t()) :: map()
  def extract!(directory) when is_binary(directory) do
    pin = pin!()
    File.mkdir_p!(directory)
    path = Path.join(directory, pin["filename"])
    ensure_source!(path, pin)

    corpus =
      path
      |> Explorer.DataFrame.from_parquet!(columns: ["Index", "Supporting_Documents"])
      |> Explorer.DataFrame.to_rows()
      |> normalize!()

    write_outputs!(directory, corpus, pin)
  end

  @doc "Normalizes benchmark rows while preserving source aliases and question mappings."
  @spec normalize!([map()]) :: %{documents: [map()], aliases: [map()], mappings: [map()]}
  def normalize!(rows) when is_list(rows) do
    {sources, questions} = Enum.reduce(rows, {%{}, %{}}, &add_row!/2)

    content_ids = Enum.group_by(sources, fn {_id, content} -> content end, fn {id, _} -> id end)

    canonical =
      for {_content, ids} <- content_ids, id <- ids, into: %{} do
        {id, Enum.min(ids)}
      end

    documents =
      content_ids
      |> Enum.map(fn {content, ids} -> %{"doc_id" => Enum.min(ids), "content" => content} end)
      |> Enum.sort_by(& &1["doc_id"])

    aliases =
      sources
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&%{"source_doc_id" => &1, "doc_id" => canonical[&1]})

    mappings =
      questions
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {index, source_ids} ->
        %{
          "question_id" => index,
          "source_doc_ids" => source_ids,
          "doc_ids" => source_ids |> Enum.map(&canonical[&1]) |> Enum.uniq()
        }
      end)

    %{documents: documents, aliases: aliases, mappings: mappings}
  end

  @doc "Refuses a cached source whose size or digest differs from the repository pin."
  @spec verify_source!(Path.t(), map()) :: :ok
  def verify_source!(path, pin) do
    bytes = File.read!(path)

    if byte_size(bytes) != pin["source_size"] or sha256(bytes) != pin["source_sha256"] do
      raise ArgumentError, "pinned Parquet checksum mismatch: #{path}"
    end

    :ok
  end

  @doc "Writes the normalized corpus and its checksum manifest."
  @spec write_outputs!(Path.t(), map(), map()) :: map()
  def write_outputs!(directory, corpus, pin) do
    File.mkdir_p!(directory)

    hashes =
      for {key, filename} <- @output_files, into: %{} do
        bytes = Enum.map_join(Map.fetch!(corpus, key), "", &encode_line(&1, key))
        File.write!(Path.join(directory, filename), bytes)
        {filename, sha256(bytes)}
      end

    manifest =
      pin
      |> Map.put("extractor_version", 1)
      |> Map.put("counts", %{
        "documents" => length(corpus.documents),
        "aliases" => length(corpus.aliases),
        "mappings" => length(corpus.mappings)
      })
      |> Map.put("sha256", hashes)

    File.write!(
      Path.join(directory, "manifest.json"),
      Jason.encode!(manifest, pretty: true) <> "\n"
    )

    manifest
  end

  defp pin! do
    Application.app_dir(:zaq, "priv/bench/liverag/pin.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp ensure_source!(path, pin) do
    if File.exists?(path) do
      verify_source!(path, pin)
    else
      url =
        "https://huggingface.co/datasets/#{pin["dataset"]}/resolve/#{pin["revision"]}/#{pin["filename"]}"

      case Req.get(url, receive_timeout: 180_000) do
        {:ok, %Req.Response{status: 200, body: bytes}} when is_binary(bytes) ->
          temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
          File.write!(temporary, bytes)

          try do
            verify_source!(temporary, pin)
            File.rename!(temporary, path)
          after
            File.rm(temporary)
          end

        {:ok, %Req.Response{status: status}} ->
          raise "pinned Parquet download failed with HTTP #{status}"

        {:error, reason} ->
          raise "pinned Parquet download failed: #{inspect(reason)}"
      end
    end
  end

  defp add_row!(%{"Index" => index, "Supporting_Documents" => documents}, {sources, questions})
       when is_integer(index) and index >= 0 and is_list(documents) and documents != [] do
    {sources, source_ids} =
      Enum.reduce(documents, {sources, []}, fn document, {acc, ids} ->
        {id, content} = source_document!(document, index)

        if Map.has_key?(acc, id) and acc[id] != content do
          raise ArgumentError, "conflicting content for source id #{id}"
        end

        {Map.put(acc, id, content), ids ++ [id]}
      end)

    source_ids = Enum.uniq(source_ids)

    if Map.has_key?(questions, index) and questions[index] != source_ids do
      raise ArgumentError, "conflicting question mapping for #{index}"
    end

    {sources, Map.put(questions, index, source_ids)}
  end

  defp add_row!(_row, _state), do: raise(ArgumentError, "malformed benchmark row")

  defp source_document!(%{"content" => content} = document, index)
       when is_binary(content) and byte_size(content) > 0 do
    if String.trim(content) == "" do
      raise ArgumentError, "malformed supporting content for question #{index}"
    end

    id =
      case Map.get(document, "doc_id") do
        nil -> "sha256:" <> sha256(content)
        value when is_binary(value) -> value
        _ -> raise ArgumentError, "malformed supporting document id"
      end

    if String.trim(id) == "" do
      raise ArgumentError, "malformed supporting document id"
    end

    {id, content}
  end

  defp source_document!(_document, index),
    do: raise(ArgumentError, "malformed supporting document for question #{index}")

  defp encode_line(record, key) do
    fields =
      case key do
        :documents -> ~w(content doc_id)
        :aliases -> ~w(doc_id source_doc_id)
        :mappings -> ~w(doc_ids question_id source_doc_ids)
      end

    encoded =
      Enum.map_join(fields, ",", fn field ->
        Jason.encode!(field) <> ":" <> Jason.encode!(record[field])
      end)

    "{" <> encoded <> "}\n"
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
