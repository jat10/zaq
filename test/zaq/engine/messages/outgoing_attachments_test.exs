defmodule Zaq.Engine.Messages.OutgoingAttachmentsTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  test "text defaults to no attachments and never echoes incoming files" do
    incoming = incoming([record()])
    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "answer"})

    assert Map.fetch!(outgoing, :attachments) == []
    assert incoming.attachments == [record()]
    refute Map.has_key?(outgoing, :delivery)
    refute Map.has_key?(outgoing, :plan)
    refute Map.has_key?(outgoing, :delivery_error)
  end

  test "supplied Records retain their order through the builder and cross-node serialization" do
    assert {:ok, sealed} = Provenance.seal(record())
    assert {:ok, restored} = sealed |> Jason.encode!() |> Jason.decode!() |> Record.from_map()
    selected = [restored, %{record() | id: "second"}, restored]

    outgoing =
      Outgoing.from_pipeline_result(incoming(), %{answer: "answer", attachments: selected})

    assert outgoing.attachments == selected
    assert :erlang.binary_to_term(:erlang.term_to_binary(outgoing)) == outgoing
    assert outgoing.body == "answer"
  end

  test "attachment payloads and Channel-only state are excluded from merged metadata" do
    private = %{
      "attachments" => [record()],
      "delivery" => %{plan: :private},
      "plan" => :private,
      "delivery_error" => :private,
      attachments: [record()],
      delivery: %{plan: :private},
      plan: :private,
      delivery_error: :private
    }

    incoming = %{incoming() | metadata: Map.put(private, :origin, :preserved)}
    result = Map.merge(private, %{answer: "answer", confidence_score: 0.8})
    outgoing = Outgoing.from_pipeline_result(incoming, result)

    assert outgoing.attachments == [record()]
    assert outgoing.metadata == %{origin: :preserved, answer: "answer", confidence_score: 0.8}
  end

  defp incoming(attachments \\ []),
    do: %Incoming{
      content: "question",
      channel_id: "room",
      provider: :mattermost,
      attachments: attachments
    }

  defp record,
    do: %Record{id: "one", kind: :file, name: "one.txt", content: "bytes", size: 5}
end
