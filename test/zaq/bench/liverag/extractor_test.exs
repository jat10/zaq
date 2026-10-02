defmodule Zaq.Bench.LiveRAG.ExtractorTest do
  use ExUnit.Case, async: true

  alias Zaq.Bench.LiveRAG.Extractor

  test "deduplicates content while retaining aliases and ordered question mappings" do
    rows = [
      row(2, [%{"doc_id" => "z", "content" => "same"}, %{"doc_id" => "b", "content" => "other"}]),
      row(1, [%{"doc_id" => "a", "content" => "same"}])
    ]

    expected = Extractor.normalize!(rows)

    assert expected == Extractor.normalize!(Enum.reverse(rows))

    assert expected.documents == [
             %{"doc_id" => "a", "content" => "same"},
             %{"doc_id" => "b", "content" => "other"}
           ]

    assert expected.aliases == [
             %{"source_doc_id" => "a", "doc_id" => "a"},
             %{"source_doc_id" => "b", "doc_id" => "b"},
             %{"source_doc_id" => "z", "doc_id" => "a"}
           ]

    assert expected.mappings == [
             %{"question_id" => 1, "source_doc_ids" => ["a"], "doc_ids" => ["a"]},
             %{"question_id" => 2, "source_doc_ids" => ["z", "b"], "doc_ids" => ["a", "b"]}
           ]
  end

  test "rejects conflicting source IDs and question mappings" do
    assert_raise ArgumentError, ~r/conflicting content/, fn ->
      Extractor.normalize!([row(0, [doc("a", "first")]), row(1, [doc("a", "second")])])
    end

    assert_raise ArgumentError, ~r/conflicting question mapping/, fn ->
      Extractor.normalize!([row(0, [doc("a", "first")]), row(0, [doc("b", "second")])])
    end
  end

  test "rejects malformed input" do
    for bad <- [
          row(-1, [doc("a", "valid")]),
          row(0, []),
          row(0, [doc("a", "")]),
          row(0, [doc(1, "valid")])
        ] do
      assert_raise ArgumentError, fn -> Extractor.normalize!([bad]) end
    end
  end

  test "missing source ID uses a content digest" do
    corpus = Extractor.normalize!([row(0, [%{"content" => "unicode café"}])])
    id = "sha256:" <> (:crypto.hash(:sha256, "unicode café") |> Base.encode16(case: :lower))

    assert corpus.documents == [%{"doc_id" => id, "content" => "unicode café"}]
    assert corpus.aliases == [%{"source_doc_id" => id, "doc_id" => id}]
    assert hd(corpus.mappings)["doc_ids"] == [id]
  end

  test "refuses a cached source with a mismatched pin" do
    path = Path.join(System.tmp_dir!(), "liverag_source_#{System.unique_integer([:positive])}")
    File.write!(path, "wrong source")
    on_exit(fn -> File.rm(path) end)

    assert_raise ArgumentError, ~r/pinned Parquet checksum mismatch/, fn ->
      Extractor.verify_source!(path, %{"source_size" => 12, "source_sha256" => "wrong"})
    end
  end

  test "output bytes are deterministic across row order" do
    rows = [row(1, [doc("b", "second")]), row(0, [doc("a", "first")])]
    root = Path.join(System.tmp_dir!(), "liverag_extract_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    pin = %{"source_sha256" => "test"}

    Extractor.write_outputs!(Path.join(root, "first"), Extractor.normalize!(rows), pin)

    Extractor.write_outputs!(
      Path.join(root, "second"),
      Extractor.normalize!(Enum.reverse(rows)),
      pin
    )

    for filename <- ~w(documents.jsonl aliases.jsonl mappings.jsonl) do
      assert File.read!(Path.join([root, "first", filename])) ==
               File.read!(Path.join([root, "second", filename]))
    end
  end

  defp row(index, documents), do: %{"Index" => index, "Supporting_Documents" => documents}
  defp doc(id, content), do: %{"doc_id" => id, "content" => content}
end
