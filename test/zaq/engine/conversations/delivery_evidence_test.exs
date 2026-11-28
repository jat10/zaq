defmodule Zaq.Engine.Conversations.DeliveryEvidenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Conversations.DeliveryEvidence

  property "accepted evidence stays bounded and discards unknown private fields across JSON round trips" do
    check all(
            group <- integer(0..100_000),
            refs <- uniq_list_of(integer(0..100_000), max_length: 128),
            {stage, operation, outcome, reason} <-
              member_of([
                {:configuration, :configure, :failed, :missing_configuration},
                {:preparation, :prepare, :failed, :size_limit},
                {:publication, :send, :unconfirmed, :timeout},
                {:upload, :upload, :failed, :rejected}
              ])
          ) do
      step =
        case operation do
          :send -> [:send, group]
          :upload -> [:upload, group, 0]
          _ -> nil
        end

      part = %{
        group_id: group,
        step_id: step,
        operation: operation,
        stage: stage,
        outcome: outcome,
        reason: reason,
        attachment_refs: refs,
        omitted_attachment_count: 0,
        cause: "PRIVATE",
        body: "PRIVATE",
        credentials: %{token: "PRIVATE"}
      }

      evidence = evidence([part])
      assert {:ok, safe} = DeliveryEvidence.normalize(Map.put(evidence, :private, "PRIVATE"))
      refute Jason.encode!(safe) =~ "PRIVATE"
      assert {:ok, replayed} = DeliveryEvidence.normalize(safe)
      assert Map.delete(hd(replayed["parts"]), "provider_code") == hd(safe["parts"])
      assert hd(safe["parts"])["attachment_refs"] == refs
    end
  end

  property "oversized part collections never enter persistence" do
    check all(count <- integer(129..150)) do
      assert {:error, :invalid_delivery_evidence} =
               DeliveryEvidence.normalize(evidence(List.duplicate(part(), count)))
    end
  end

  defp evidence(parts),
    do: %{
      version: 1,
      attempt_id: Ecto.UUID.generate(),
      parts: parts,
      confirmed_message_count: 1,
      confirmed_attachment_count: 0,
      omitted_part_count: 0
    }

  defp part,
    do: %{
      group_id: 0,
      step_id: [:send, 0],
      operation: :send,
      stage: :publication,
      outcome: :unconfirmed,
      reason: :timeout,
      attachment_refs: [],
      omitted_attachment_count: 0
    }
end
