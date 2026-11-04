defmodule Zaq.System.ClassificationThresholdTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.System, as: Settings
  alias Zaq.System.RAGModelConfig

  test "missing threshold defaults to 80 and Decision saves preserve unrelated settings" do
    assert Settings.get_rag_model_config(:decision).classification_threshold == 80
    Settings.set_config("rag.reranking.model", "keep")

    assert {:ok, %{classification_threshold: 95}} =
             Settings.save_rag_model_config(:decision, %{classification_threshold: "95"})

    assert Settings.get_rag_model_config(:decision).classification_threshold == 95
    assert Settings.get_config("rag.reranking.model") == "keep"
    assert {:ok, %{classification_threshold: 95}} = Settings.save_rag_model_config(:decision, %{})
  end

  property "only whole percentages from zero through 100 are accepted" do
    check all(percent <- integer(-1000..1000)) do
      changeset =
        RAGModelConfig.changeset(%RAGModelConfig{}, %{classification_threshold: percent})

      assert changeset.valid? == percent in 0..100
    end
  end

  test "invalid thresholds never overwrite the saved value" do
    for value <- [-1, 101, "bad", "80.5", ""] do
      assert {:error, %Ecto.Changeset{}} =
               Settings.save_rag_model_config(:decision, %{classification_threshold: value})

      assert Settings.get_rag_model_config(:decision).classification_threshold == 80
    end
  end
end
