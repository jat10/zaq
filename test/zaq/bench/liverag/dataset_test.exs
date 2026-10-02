defmodule Zaq.Bench.LiveRAG.DatasetTest do
  use ExUnit.Case, async: true

  alias Zaq.Bench.LiveRAG.Dataset

  test "loads verified extracted documents and mappings" do
    dir = Path.join(System.tmp_dir!(), "liverag-dataset-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    documents = ~s({"doc_id":"a","content":"alpha"}\n)
    mappings = ~s({"question_id":0,"source_doc_ids":["a"],"doc_ids":["a"]}\n)
    aliases = ~s({"source_doc_id":"a","doc_id":"a"}\n)

    for {name, body} <- [
          {"documents.jsonl", documents},
          {"mappings.jsonl", mappings},
          {"aliases.jsonl", aliases}
        ] do
      File.write!(Path.join(dir, name), body)
    end

    hashes =
      for name <- ["documents.jsonl", "mappings.jsonl", "aliases.jsonl"], into: %{} do
        body = File.read!(Path.join(dir, name))
        {name, Base.encode16(:crypto.hash(:sha256, body), case: :lower)}
      end

    pin =
      :zaq
      |> Application.app_dir("priv/bench/liverag/pin.json")
      |> File.read!()
      |> Jason.decode!()

    manifest =
      Map.merge(pin, %{
        "extractor_version" => 1,
        "sha256" => hashes,
        "counts" => %{"documents" => 1, "aliases" => 1, "mappings" => 1}
      })

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))

    assert {:ok, dataset} = Dataset.load(dir)
    assert dataset.documents == [%{"doc_id" => "a", "content" => "alpha"}]

    assert dataset.mappings == [
             %{"question_id" => 0, "source_doc_ids" => ["a"], "doc_ids" => ["a"]}
           ]

    File.write!(Path.join(dir, "documents.jsonl"), "tampered\n")
    assert {:error, {:checksum_mismatch, "documents.jsonl"}} = Dataset.load(dir)

    File.write!(Path.join(dir, "documents.jsonl"), documents)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(Map.put(manifest, "revision", "wrong"))
    )

    assert {:error, :source_pin_mismatch} = Dataset.load(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(Map.put(manifest, "extractor_version", 2))
    )

    assert {:error, :source_pin_mismatch} = Dataset.load(dir)

    inconsistent_mapping = ~s({"question_id":0,"source_doc_ids":["a"],"doc_ids":[]}\n)
    File.write!(Path.join(dir, "mappings.jsonl"), inconsistent_mapping)

    updated_hashes =
      Map.put(
        hashes,
        "mappings.jsonl",
        Base.encode16(:crypto.hash(:sha256, inconsistent_mapping), case: :lower)
      )

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(Map.put(manifest, "sha256", updated_hashes))
    )

    assert {:error, :invalid_reference} = Dataset.load(dir)
  end
end
