defmodule Zaq.Ingestion.Python.Steps.ImageDedupCrawlerTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.Python.Runner
  alias Zaq.Ingestion.Python.Steps.ImageDedup

  # An 8x8 checkerboard PNG; the second file has identical bytes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAGElEQVR4nGP4//8/AwMDJsmAVRREDkodAF1zX6Fn/mpxAAAAAElFTkSuQmCC"
       )

  test "the fetched crawler removes a duplicate using the installed Python environment" do
    assert Runner.python_executable() == Path.join(File.cwd!(), ".venv/bin/python3")

    images_dir =
      Path.join(System.tmp_dir!(), "zaq_image_dedup_#{System.unique_integer([:positive])}")

    File.mkdir_p!(images_dir)
    on_exit(fn -> File.rm_rf!(images_dir) end)

    File.write!(Path.join(images_dir, "first.png"), @png)
    File.write!(Path.join(images_dir, "second.png"), @png)

    assert {:ok, _output} = ImageDedup.run(images_dir)

    remaining_images = Path.wildcard(Path.join(images_dir, "*.png"))
    assert length(remaining_images) == 1
    assert File.read!(hd(remaining_images)) == @png
    assert File.read!(Path.join(images_dir, "duplicate_mapping.txt")) =~ "# Total duplicates: 1"
  end
end
