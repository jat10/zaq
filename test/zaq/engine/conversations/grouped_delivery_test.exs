defmodule Zaq.Engine.Conversations.GroupedDeliveryTest do
  use Zaq.DataCase, async: true
  import Zaq.ChannelDeliveryFixtures
  import Zaq.AccountsFixtures

  alias Zaq.Channels.Delivery.{Error, Plan, Result}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.{DeliveryConfirmation, TransportRequirements}
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  test "real Channels-to-Engine reporting persists successful messages and one supplemental failure group" do
    ctx = stored_channel_answer()
    outgoing = outgoing(ctx)
    response = {:ok, result()}
    assert ^response = DeliveryConfirmation.record_attempt(response, outgoing, [])
    answer = Repo.get!(Message, ctx.answer.id)
    assert answer.metadata["delivery_confirmation"]["message_id"] == "root"
    assert answer.metadata["delivery_parts"]["parts"] |> length() == 1

    assert [%{"outcome" => "unconfirmed", "reason" => "timeout"}] =
             answer.metadata["delivery_parts"]["parts"]

    assert Repo.get_by(TranscriptMessage, message_id: answer.id)
    continuation = Repo.get_by!(Message, external_message_id: "continuation")
    assert continuation.content == "Additional files (3/3)."
    assert continuation.metadata["delivery_part"]["thread_id"] == "root"
    assert Repo.get_by(TranscriptMessage, message_id: continuation.id)

    assert Repo.aggregate(
             from(m in Message, where: m.external_message_id in ["root", "continuation"]),
             :count
           ) == 2

    assert ^response = DeliveryConfirmation.record_attempt(response, outgoing, [])

    assert Repo.aggregate(
             from(m in Message, where: m.external_message_id in ["root", "continuation"]),
             :count
           ) == 2

    assert Repo.get!(Message, answer.id).metadata == answer.metadata
    assert MessageDelivery.presentation(answer).state == :partial
    refute inspect(answer.metadata["delivery_parts"]) =~ "PRIVATE"
  end

  test "grouped evidence uses exact persisted input, answer and connector association" do
    ctx = stored_channel_answer()
    other = stored_channel_answer()
    assert {:ok, evidence} = Result.safe_evidence(result())

    base = %{
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id,
      channel_config_id: ctx.config.id,
      delivery_parts: evidence
    }

    for request <- [
          %{base | user_message_id: other.input.id},
          %{base | channel_config_id: other.config.id},
          %{base | assistant_message_id: other.answer.id}
        ] do
      event =
        Event.new(request, :engine,
          opts: [action: :record_delivery_observation, confidential: true]
        )

      assert %{response: {:error, :invalid_delivery_scope}} = NodeRouter.dispatch(event)
    end

    assert Repo.get!(Message, ctx.answer.id).metadata == ctx.answer.metadata
    assert {:ok, :recorded} = MessageDelivery.record(base)
    assert {:ok, :unchanged} = MessageDelivery.record(base)
    assert Repo.get!(Message, ctx.answer.id).content == ctx.answer.content
  end

  test "malformed, oversized or uncertain-as-rejected evidence cannot be persisted" do
    ctx = stored_channel_answer()
    assert {:ok, evidence} = Result.safe_evidence(result())
    [part] = evidence.parts

    for invalid <- [
          %{evidence | parts: List.duplicate(part, 129)},
          %{evidence | parts: [%{part | outcome: :failed, reason: :timeout}]},
          %{evidence | attempt_id: "invalid"}
        ] do
      assert {:error, :invalid_delivery_observation} =
               MessageDelivery.record(%{
                 user_message_id: ctx.input.id,
                 assistant_message_id: ctx.answer.id,
                 channel_config_id: ctx.config.id,
                 delivery_parts: invalid
               })
    end

    assert Repo.get!(Message, ctx.answer.id).metadata == ctx.answer.metadata
  end

  test "authorized canonical history exposes grouped facts without a duplicate pending bubble" do
    ctx = stored_channel_answer()
    assert {:ok, _} = DeliveryConfirmation.record_attempt({:ok, result()}, outgoing(ctx), [])
    admin = super_admin_fixture()

    event =
      Event.new(%{op: :detail, id: ctx.captured.transcript_id}, :engine,
        actor: %{user_id: admin.id},
        opts: [action: :channel_history_admin, confidential: true]
      )

    assert %{response: {:ok, detail}} = NodeRouter.dispatch(event)
    assert detail.pending_messages == []

    assert [%{delivery: %{state: :partial, parts: [_]}}] =
             Enum.filter(detail.messages, &(&1.message_id == ctx.answer.id))

    refute inspect(detail.messages) =~ "PRIVATE"
    assert %{response: {:error, _}} = NodeRouter.dispatch(%{event | actor: nil})
  end

  test "confirmation preserves earlier grouped evidence while legacy late failures remain ignored" do
    ctx = stored_channel_answer()
    response = {:ok, result()}
    assert {:ok, evidence} = Result.safe_evidence(elem(response, 1))

    scope = %{
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id,
      channel_config_id: ctx.config.id
    }

    assert {:ok, :recorded} = MessageDelivery.record(Map.put(scope, :delivery_parts, evidence))
    parts = Repo.get!(Message, ctx.answer.id).metadata["delivery_parts"]
    assert ^response = DeliveryConfirmation.record_attempt(response, outgoing(ctx), [])
    confirmed = Repo.get!(Message, ctx.answer.id)
    assert confirmed.metadata["delivery_parts"] == parts

    assert {:ok, :confirmed} =
             MessageDelivery.record(Map.merge(scope, %{outcome: :failed, reason: :rejected}))

    assert Repo.get!(Message, ctx.answer.id).metadata == confirmed.metadata
  end

  defp outgoing(ctx),
    do: %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: ctx.answer.content,
      routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room},
      metadata: %{
        user_message_id: ctx.input.id,
        assistant_message_id: ctx.answer.id,
        persisted_assistant_message_id: ctx.answer.id
      }
    }

  defp result do
    steps = for group <- 0..2, do: %Step{id: {:send, group}, operation: :send, group_id: group}

    plan = %Plan{
      requirements: %TransportRequirements{
        transfer_mode: :send_with_attachments,
        max_attachments_per_message: 1
      },
      groups: [],
      steps: steps,
      placement: :threaded
    }

    outcomes = %{
      {:send, 0} => %{
        outcome: :confirmed,
        receipt: %{confirmation: :confirmed, message_id: "root"},
        publication: %{body: "formatted answer", thread_id: nil, continuation?: false}
      },
      {:send, 1} => %{
        outcome: :unconfirmed,
        error: %Error{
          stage: :publication,
          outcome: :unconfirmed,
          reason: :timeout,
          cause: "PRIVATE"
        }
      },
      {:send, 2} => %{
        outcome: :confirmed,
        receipt: %{confirmation: :confirmed, message_id: "continuation", thread_id: "root"},
        publication: %{body: "Additional files (3/3).", thread_id: "root", continuation?: true}
      }
    }

    Result.new(plan, outcomes, Ecto.UUID.generate())
  end
end
