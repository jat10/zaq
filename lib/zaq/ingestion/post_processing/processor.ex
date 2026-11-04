defmodule Zaq.Ingestion.PostProcessing.Processor do
  @moduledoc "Contract for Ingestion-owned post-processing with processor-owned eligibility and results."
  @callback eligible?(map(), map()) :: boolean()
  @callback reserve(map(), map()) :: [map()]
  @callback perform(struct(), keyword()) :: :ok | {:skip, atom()} | {:error, atom()}
end
