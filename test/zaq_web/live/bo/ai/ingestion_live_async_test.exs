defmodule ZaqWeb.Live.BO.AI.IngestionLiveAsyncTest do
  use ZaqWeb.ConnCase, async: true

  alias ZaqWeb.Live.BO.AI.IngestionLive

  describe "format_size/1" do
    test "bytes < 1024 shows B suffix" do
      assert IngestionLive.format_size(512) == "512 B"
    end

    test "bytes < 1 MB shows KB suffix" do
      assert IngestionLive.format_size(2048) == "2.0 KB"
    end

    test "bytes >= 1 MB shows MB suffix" do
      assert IngestionLive.format_size(2_097_152) == "2.0 MB"
    end
  end

  describe "status_pill_classes/1" do
    test "pending returns elevated pill classes" do
      assert "zaq-pill" in IngestionLive.status_pill_classes("pending")
      assert "zaq-pill--elevated" in IngestionLive.status_pill_classes("pending")
    end

    test "processing returns accent pill classes" do
      assert "zaq-pill--accent" in IngestionLive.status_pill_classes("processing")
    end

    test "completed returns success pill classes" do
      assert "zaq-pill--success" in IngestionLive.status_pill_classes("completed")
    end

    test "failed returns danger pill classes" do
      assert "zaq-pill--danger" in IngestionLive.status_pill_classes("failed")
    end

    test "unknown status returns elevated fallback" do
      assert "zaq-pill--elevated" in IngestionLive.status_pill_classes("unknown")
    end

    test "completed_with_errors returns warning pill classes" do
      assert "zaq-pill--warning" in IngestionLive.status_pill_classes("completed_with_errors")
    end
  end

  describe "file_url/1" do
    test "returns /bo/files/ prefixed URL" do
      assert IngestionLive.file_url("docs/guide.md") == "/bo/files/docs/guide.md"
    end

    test "strips leading ./ from path" do
      assert IngestionLive.file_url("./report.pdf") == "/bo/files/report.pdf"
    end

    test "handles simple filename" do
      assert IngestionLive.file_url("file.txt") == "/bo/files/file.txt"
    end
  end
end
