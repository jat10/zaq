defmodule Zaq.Ingestion.PostProcessing.Processors.Labeling do
  @moduledoc "Maps the shared processor lifecycle onto Ingestion-owned label automation."
  @behaviour Zaq.Ingestion.PostProcessing.Processor
  alias Zaq.Ingestion.Labels.Automation
  @impl true
  defdelegate eligible?(resource, context), to: Automation
  @impl true
  defdelegate reserve(resource, context), to: Automation
  @impl true
  defdelegate perform(request, opts), to: Automation
end
