defmodule ZaqWeb.ClassificationThresholdUITest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Zaq.System.{
    EmbeddingConfig,
    ImageToTextConfig,
    LLMConfig,
    OperationModelConfig,
    RAGModelConfig
  }

  alias ZaqWeb.Live.BO.System.SystemConfig.RAGTab

  test "Decision alone exposes the shared percentage with future-request guidance" do
    form = fn module, name ->
      Phoenix.Component.to_form(module.changeset(struct(module), %{}), as: name)
    end

    html =
      render_component(&RAGTab.panel/1,
        embedding_form: form.(EmbeddingConfig, :embedding_config),
        image_to_text_form: form.(ImageToTextConfig, :image_to_text_config),
        retrieval_form:
          Phoenix.Component.to_form(LLMConfig.retrieval_changeset(%LLMConfig{}, %{})),
        translation_form: form.(OperationModelConfig, :operation_model_config),
        model_forms:
          Map.new([:decision, :reranking], &{&1, form.(RAGModelConfig, :rag_model_config)}),
        credential_options: [],
        translation_model_options: [],
        embedding_model_options: [],
        image_to_text_model_options: [],
        model_options: %{decision: [], reranking: []},
        locked: false,
        unlock_modal: false,
        save_confirm_modal: false,
        model_changed: false
      )

    doc = LazyHTML.from_fragment(html)

    assert Enum.count(
             LazyHTML.query(
               doc,
               "#rag-decision-form input[name='rag_model_config[classification_threshold]'][value='80']"
             )
           ) == 1

    assert Enum.empty?(
             LazyHTML.query(
               doc,
               "#rag-reranking-form input[name='rag_model_config[classification_threshold]']"
             )
           )

    assert html =~ "future classification requests"
  end
end
