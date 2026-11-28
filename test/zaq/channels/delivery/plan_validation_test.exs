defmodule Zaq.Channels.Delivery.PlanValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Attachments, Plan}
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  test "generated upload and direct-send plans validate without acquiring content" do
    for mode <- [:upload_then_publish, :send_with_attachments] do
      plan = plan(3, mode)
      assert :ok = Plan.validate(plan, 3)
      refute_received _
    end
  end

  test "invalid group and original attachment references are rejected" do
    plan = plan(2)
    [first, second] = plan.groups

    for invalid <- [
          %{plan | groups: [first, first]},
          %{plan | groups: [first]},
          %{plan | groups: [first, %{second | attachment_refs: [2]}]},
          %{plan | groups: [first, %{second | attachment_refs: [-1]}]},
          %{plan | groups: [first, %{second | attachment_refs: [0]}]},
          %{plan | placement: :unknown}
        ] do
      assert {:error, :invalid_delivery_plan} = Plan.validate(invalid, 2)
    end

    assert {:error, :invalid_delivery_plan} = Plan.validate(plan, -1)
    assert {:error, :invalid_delivery_plan} = Plan.validate(nil, 2)
  end

  test "duplicate IDs, missing dependencies and cycles fail before effects" do
    plan = plan(1)
    [upload, publication] = plan.steps

    for steps <- [
          [upload, upload],
          [upload, %{publication | depends_on: [{:upload, 0, 99}]}],
          [%{upload | depends_on: [publication.id]}, publication],
          [%{upload | depends_on: [upload.id]}, publication],
          [upload, %{publication | attachment_refs: [1]}],
          [upload, %{publication | group_id: 99}],
          [upload, %{publication | operation: :delete}]
        ] do
      assert {:error, :invalid_delivery_plan} = Plan.validate(%{plan | steps: steps}, 1)
      refute_received _
    end
  end

  test "edits require the explicit attachment capability and an existing target" do
    plan = plan(1, :send_with_attachments)
    [publication] = plan.steps
    edit = %{publication | id: {:edit, 0}, operation: :edit, message_ref: {:existing, "prior"}}
    edited = %{plan | steps: [edit]}

    assert {:error, :invalid_delivery_plan} = Plan.validate(edited, 1)
    edited = %{edited | requirements: %{edited.requirements | supports_attachment_edits: true}}
    assert :ok = Plan.validate(edited, 1)

    assert {:error, :invalid_delivery_plan} =
             Plan.validate(%{edited | steps: [%{edit | message_ref: nil}]}, 1)
  end

  property "planner output preserves every original index across fixed groups" do
    check all(count <- integer(1..20), limit <- integer(1..5)) do
      plan = plan(count, :upload_then_publish, limit)
      assert :ok = Plan.validate(plan, count)
      assert Enum.flat_map(plan.groups, & &1.attachment_refs) == Enum.to_list(0..(count - 1))
    end
  end

  defp plan(count, mode \\ :upload_then_publish, limit \\ 1) do
    records =
      for index <- 0..(count - 1) do
        %Record{id: "file-#{index}", kind: :file, size: 1, materialization_handle: "unredeemed"}
      end

    outgoing = %Outgoing{
      body: "answer",
      provider: :test,
      channel_id: "room",
      attachments: records
    }

    requirements = %TransportRequirements{transfer_mode: mode, max_attachments_per_message: limit}
    {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    plan
  end
end
