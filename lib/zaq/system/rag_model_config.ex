defmodule Zaq.System.RAGModelConfig do
  @moduledoc """
  Specialized RAG model selection and shared Decision classification threshold.
  Saving settings does not invoke a model. Decision inference additionally requires
  an eligible consumer; model eligibility uses explicit catalog capabilities.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :credential_id, :integer
    field :model, :string
    field :classification_threshold, :integer, default: 80
  end

  def changeset(config, attrs) do
    changeset =
      config
      |> cast(attrs, [:credential_id, :model])
      |> cast(attrs, [:classification_threshold], empty_values: [])
      |> validate_required([:classification_threshold])
      |> validate_number(:classification_threshold,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )

    if get_field(changeset, :credential_id) || get_field(changeset, :model) do
      changeset
      |> validate_required([:credential_id, :model])
      |> validate_number(:credential_id, greater_than: 0)
    else
      changeset
    end
  end

  @doc "Whether catalog metadata explicitly supports the requested specialized purpose."
  def supports?(model, :reranking),
    do: get_in(model, [Access.key(:capabilities, %{}), :rerank]) == true

  def supports?(model, :decision) do
    output = get_in(model, [Access.key(:modalities, %{}), :output]) || []
    :decisions in output or get_in(model, [Access.key(:capabilities, %{}), :evaluate]) == true
  end
end
