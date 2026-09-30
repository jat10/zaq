defmodule Zaq.Bench.LiveRAG.Configuration do
  @moduledoc """
  Resolves one persisted embedding snapshot for a standalone LiveRAG corpus run.

  Provider authentication remains ephemeral. OAuth is refused at Connect's
  locked selection point, before any refresh can mutate the source database.
  """

  alias Zaq.Bench.LiveRAG.Database
  alias Zaq.Engine.Connect.AIRuntimeCredentials
  alias Zaq.Identity.ExecutionActor
  alias Zaq.System

  @chunk_contract_version 1
  @extractor_contract_version 1

  @enforce_keys [:embedding, :provider, :resolved_credential, :fingerprint]
  @derive {Inspect, only: [:fingerprint]}
  defstruct @enforce_keys ++ [contract: %{}]

  @type t :: %__MODULE__{
          embedding: struct(),
          provider: map(),
          resolved_credential: Zaq.Engine.Connect.ResolvedCredential.t(),
          fingerprint: String.t(),
          contract: map()
        }

  @doc "Loads the source database's persisted configuration for a trusted execution actor."
  @spec load(%{source: pid() | atom()}, map()) :: {:ok, t()} | {:error, term()}
  def load(database, actor) do
    with {:ok, actor} <- ExecutionActor.validate(actor) do
      Database.with_source(database, fn -> load_from_source(actor) end)
    end
  end

  @doc "Builds an ephemeral `Embedding.Client` config for supported authentication modes."
  @spec embedding_client_config(t()) :: {:ok, map()} | {:error, :unsupported_embedding_auth_kind}
  def embedding_client_config(%__MODULE__{embedding: embedding, provider: provider} = snapshot) do
    case snapshot.resolved_credential do
      %{auth_kind: "api_key", request_format: "bearer", authentication: %{api_key: key}} ->
        {:ok, %{endpoint: provider.endpoint, model: embedding.model, api_key: key}}

      %{auth_kind: "none", authentication: %{}} ->
        {:ok, %{endpoint: provider.endpoint, model: embedding.model, api_key: ""}}

      _ ->
        {:error, :unsupported_embedding_auth_kind}
    end
  end

  defp load_from_source(actor) do
    embedding = System.get_embedding_config_snapshot()

    with :ok <- validate_embedding(embedding),
         {:ok, %{credential: provider, resolved_credential: resolved}} <-
           AIRuntimeCredentials.resolve(embedding.credential_id, actor, reject_oauth: true),
         {:ok, pin} <- read_pin() do
      provider = Map.take(provider, [:id, :provider, :endpoint, :connect_credential_id])

      contract = preparation_contract(embedding)

      {:ok,
       %__MODULE__{
         embedding: embedding,
         provider: provider,
         resolved_credential: resolved,
         fingerprint: fingerprint(pin, embedding, provider, resolved, contract),
         contract: contract
       }}
    else
      {:ok, nil} -> {:error, :embedding_provider_missing}
      other -> other
    end
  end

  defp validate_embedding(%{credential_id: id}) when not is_integer(id) or id <= 0,
    do: {:error, :embedding_credential_missing}

  defp validate_embedding(%{model: model, dimension: dimension} = embedding) do
    if is_binary(model) and String.trim(model) != "" and is_integer(dimension) and
         dimension > 0 and dimension <= 4000 and valid_chunk_range?(embedding),
       do: :ok,
       else: {:error, :invalid_embedding_configuration}
  end

  defp valid_chunk_range?(%{chunk_min_tokens: min, chunk_max_tokens: max}) do
    is_integer(min) and is_integer(max) and min > 0 and max >= min
  end

  defp read_pin do
    path = Application.app_dir(:zaq, "priv/bench/liverag/pin.json")

    with {:ok, bytes} <- File.read(path), {:ok, pin} <- Jason.decode(bytes) do
      {:ok, pin}
    else
      _ -> {:error, :source_pin_unavailable}
    end
  end

  @doc "Returns the nonsecret configuration and revision contract used to prepare vectors."
  def preparation_contract(embedding) do
    source_paths = [
      "lib/zaq/bench/live_rag/runner.ex",
      "lib/zaq/bench/live_rag/checkpoint.ex",
      "lib/zaq/ingestion/document_processor.ex",
      "lib/zaq/ingestion/document_chunker.ex",
      "lib/zaq/ingestion/chunk_persistence.ex",
      "lib/zaq/ingestion/fts_backend.ex",
      "lib/zaq/ingestion/fts_backend/native.ex",
      "lib/zaq/embedding/client.ex"
    ]

    root = Path.expand("../../../..", __DIR__)

    %{
      "model" => embedding.model,
      "dimension" => embedding.dimension,
      "chunk_min_tokens" => embedding.chunk_min_tokens,
      "chunk_max_tokens" => embedding.chunk_max_tokens,
      "code_revision" =>
        source_paths
        |> Map.new(&{&1, file_sha256!(Path.join(root, &1))})
        |> Jason.encode!()
        |> sha256(),
      "dependency_revision" => file_sha256!(Path.join(root, "mix.lock"))
    }
  end

  defp file_sha256!(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp fingerprint(pin, embedding, provider, resolved, contract) do
    [
      contract,
      pin["revision"],
      pin["source_sha256"],
      @extractor_contract_version,
      @chunk_contract_version,
      embedding.credential_id,
      embedding.model,
      embedding.dimension,
      embedding.chunk_min_tokens,
      embedding.chunk_max_tokens,
      provider.id,
      provider.provider,
      provider.endpoint,
      provider.connect_credential_id,
      resolved.credential_id,
      resolved.grant_id,
      resolved.owner_type,
      resolved.owner_id,
      resolved.auth_kind,
      resolved.request_format
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
