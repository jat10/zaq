defmodule Zaq.Channels.Delivery.Preparation do
  @moduledoc """
  Explicit content acquisition primitives for a future Channel delivery executor.

  Redeems lazy Records through `Zaq.Materialization`, retaining its signed-handle
  authorization contract. Only trusted identity, literal permission bypass and
  local router/config dependencies are supplied to redemption. Nil identity never
  creates a bypass. Materialized Records are treated as already authorized bytes.

  Acquired content is transient and separate from source Records and delivery
  plans. This module does not regroup, encode provider requests, upload or send.
  The executor must also validate fixed groups with `Attachments.validate_group/2`
  and `validate_upload_group/2`, then check actual encoded provider requests against
  resolved transport limits.
  """

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Channels.Delivery.Attachments
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @type attachment :: %{
          content: binary(),
          size: non_neg_integer(),
          name: String.t(),
          mime_type: String.t()
        }

  @doc """
  Acquires one Record and checks metadata and actual raw byte limits.

  Absent, binary and UTF-8 encoding preserve content bytes; explicitly declared
  standard base64 is decoded. Returns transient bytes with safe display defaults and actual
  size; metadata size drift is accepted when actual limits permit it. Optional
  unresolved limits remain deferred to the provider. Source Records are unchanged.
  """
  @spec acquire(Record.t(), TransportRequirements.t(), map()) ::
          {:ok, attachment()} | {:error, term()}
  def acquire(record, requirements, context \\ %{})

  def acquire(record, requirements, context) when is_map(context) do
    with :ok <- Attachments.validate_requirements(requirements),
         :ok <- Attachments.validate_metadata(record),
         {:ok, materialized} <- materialize(record, trusted_context(context)),
         :ok <- Attachments.validate_metadata(materialized),
         {:ok, content} <- decode_content(materialized),
         attachment = %{
           content: content,
           size: byte_size(content),
           name: materialized.name || record.name || "attachment",
           mime_type: materialized.mime_type || record.mime_type || "application/octet-stream"
         },
         :ok <- Attachments.validate_group([attachment], requirements) do
      {:ok, attachment}
    end
  rescue
    _ -> {:error, :attachment_preparation_exception}
  catch
    _, _ -> {:error, :attachment_preparation_exit}
  end

  def acquire(_record, _requirements, _context), do: {:error, :invalid_trusted_context}

  defp trusted_context(context) do
    context
    |> TrustedContext.normalize()
    |> Map.from_struct()
    |> Map.merge(Map.take(context, [:node_router, :config]))
  end

  defp materialize(%Record{content: content} = record, _context) when is_binary(content),
    do: {:ok, record}

  defp materialize(%Record{content: nil, materialization_handle: handle}, context)
       when is_binary(handle) and handle != "" do
    case Materialization.materialize(handle, context, "Attachment acquisition failed") do
      {:ok, %{record: record}} -> {:ok, record}
      {:error, _} = error -> error
    end
  end

  defp materialize(%Record{content: nil}, _context),
    do: {:error, :attachment_content_unavailable}

  defp materialize(_record, _context), do: {:error, :invalid_attachment_content}

  defp decode_content(%Record{content: content, attributes: attributes})
       when is_binary(content) do
    case Map.get(attributes, "encoding", Map.get(attributes, :encoding)) do
      "base64" ->
        case Jido.Exec.run(DecodeBase64, %{data: content, variant: "standard"}, %{}) do
          {:ok, %{decoded: bytes}} -> {:ok, bytes}
          {:error, _} -> {:error, :invalid_attachment_base64}
        end

      encoding when encoding in [nil, "binary", "utf-8"] ->
        {:ok, content}

      _ ->
        {:error, :invalid_attachment_encoding}
    end
  end

  defp decode_content(_record), do: {:error, :invalid_attachment_content}
end
