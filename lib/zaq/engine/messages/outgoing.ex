defmodule Zaq.Engine.Messages.Outgoing do
  @moduledoc """
  Canonical outbound message payload struct.

  Produced by configured-agent execution and by the Notification center.
  Delivered through `Zaq.NodeRouter.dispatch/1` to `Zaq.Channels.Api`
  (action `:deliver_outgoing`), which resolves the provider bridge
  and calls `bridge.send_reply/2`.

  Nothing inside ZAQ should depend on adapter-specific envelope types — all outbound
  delivery flows through this struct.

  `thread_anchor` is the opaque prior-thread anchor resolved by the notification
  center (string keys: `"message_id"`, `"references"`, `"thread_id"`). It is
  interpreted only by the provider bridge; bridges that do not thread ignore it.

  For cross-node routing, this struct is typically carried in `%Zaq.Event.response`.

  `attachments` contains explicitly supplied attachment Records. Channel owns
  metadata planning and content acquisition; plans never travel in this payload.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  @enforce_keys [:body, :channel_id, :provider]

  defstruct [
    :body,
    :channel_id,
    :thread_id,
    :author_id,
    :author_name,
    :provider,
    :in_reply_to,
    :thread_anchor,
    attachments: [],
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
          attachments: [Record.t()],
          routing_context: RoutingContext.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an `%Outgoing{}` from an `%Incoming{}` and the pipeline result map.

  Copies routing fields (channel_id, thread_id, author_id, author_name, provider) from
  the incoming message and sets `body` from `result.answer`. Only attachments
  explicitly supplied in the result are propagated; incoming files are never echoed.
  Metadata retains ordinary result fields (answer, confidence_score, latency_ms,
  tokens, error), excluding attachments and Channel-local delivery state.
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
      routing_context: incoming.routing_context,
      attachments: Map.get(result, :attachments, []),
      metadata:
        incoming.metadata
        |> Map.merge(result)
        |> Map.drop([
          :attachments,
          "attachments",
          :delivery,
          "delivery",
          :plan,
          "plan",
          :delivery_error,
          "delivery_error"
        ])
        |> put_person(incoming.person)
    }
  end

  defp put_person(metadata, nil), do: metadata
  defp put_person(metadata, person), do: Map.put(metadata, :person, person)
end
