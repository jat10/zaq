defmodule Zaq.Ingestion.Actions.ReclassifyLabelChunks do
  @moduledoc "Validated preview/confirmation operation for authorized affected-chunk reclassification."
  use Jido.Action,
    name: "reclassify_label_chunks",
    description:
      "Preview or explicitly confirm reclassification of current chunks carrying an edited label",
    schema:
      Zoi.object(%{
        label_id: Zoi.integer(),
        expected_version: Zoi.integer(),
        confirm: Zoi.boolean() |> Zoi.default(false),
        confirmation_token: Zoi.string() |> Zoi.default("")
      }),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels.Reclassification

  @impl Jido.Action
  def run(params, context) do
    result =
      if params.confirm do
        Reclassification.confirm(
          params.label_id,
          params.expected_version,
          params.confirmation_token,
          context[:actor],
          Map.get(context, :opts, [])
        )
      else
        Reclassification.preview(params.label_id, params.expected_version, context[:actor])
      end

    {:ok, %{result: result}}
  end
end
