defmodule Zaq.Engine.Messages.Outgoing do
  @moduledoc """
  Canonical outbound message payload struct.

  Produced by configured-agent execution and by the Notification center.
  Delivered through `Zaq.NodeRouter.dispatch/1` to `Zaq.Channels.Api`
  (action `:deliver_outgoing`), which resolves the provider bridge
  and calls `bridge.send_reply/2`.

  Nothing inside ZAQ should depend on adapter-specific envelope types — all outbound
  delivery flows through this struct.

  `delivery.attachments` contains explicitly requested `Zaq.Contracts.Record` values. Incoming
  attachments are never automatically echoed, and runtime attachment collections
  are excluded from metadata.
  `delivery.error` carries a rejected selection independently of answer success,
  while the Agent composes selection feedback into its answer.
  `delivery.plan` is private Channel execution data, excluded from inspection,
  producer metadata and delivery confirmations.

  `thread_anchor` is the opaque prior-thread anchor resolved by the notification
  center (string keys: `"message_id"`, `"references"`, `"thread_id"`). It is
  interpreted only by the provider bridge; bridges that do not thread ignore it.

  For cross-node routing, this struct is typically carried in `%Zaq.Event.response`.
  """

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Engine.Messages.Outgoing.Delivery

  @enforce_keys [:body, :channel_id, :provider]
  @derive {Inspect, except: [:delivery]}

  defstruct [
    :body,
    :channel_id,
    :thread_id,
    :author_id,
    :author_name,
    :provider,
    :in_reply_to,
    :thread_anchor,
    delivery: %Delivery{},
    routing_context: %RoutingContext{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          body: String.t(),
          channel_id: String.t(),
          thread_id: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          provider: atom() | String.t(),
          in_reply_to: String.t() | integer() | nil,
          thread_anchor: map() | nil,
          delivery: Delivery.t(),
          routing_context: RoutingContext.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an `%Outgoing{}` from an `%Incoming{}` and the pipeline result map.

  Copies routing fields (channel_id, thread_id, author_id, author_name, provider) from
  the incoming message, sets `body` from `result.answer`, and merges result metadata
  (answer, confidence_score, latency_ms, tokens, error).

  Copies typed or restored `result.delivery` selection, defaulting to an empty
  Delivery. Legacy pipeline attachment/error keys remain accepted. Producer plans
  are discarded.
  Producers own the Record contract; Channels validates attachments during delivery.
  Attachment keys are excluded from merged metadata, including any incoming values.
  """
  @spec from_pipeline_result(Incoming.t(), map()) :: t()
  def from_pipeline_result(%Incoming{} = incoming, result) when is_map(result) do
    %__MODULE__{
      body: result.answer,
      channel_id: incoming.channel_id,
      thread_id: incoming.thread_id,
      author_id: incoming.author_id,
      author_name: incoming.author_name,
      provider: incoming.provider,
      in_reply_to: incoming.message_id,
      delivery: Delivery.from_result(result),
      routing_context: incoming.routing_context,
      metadata:
        incoming.metadata
        |> Map.merge(result)
        |> Map.drop([
          :delivery,
          "delivery",
          :attachments,
          "attachments",
          :attachment_error,
          "attachment_error",
          :delivery_plan,
          "delivery_plan"
        ])
        |> put_person(incoming.person)
    }
  end

  defp put_person(metadata, nil), do: metadata
  defp put_person(metadata, person), do: Map.put(metadata, :person, person)
end
