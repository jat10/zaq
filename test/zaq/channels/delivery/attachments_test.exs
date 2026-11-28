defmodule Zaq.Channels.Delivery.AttachmentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Attachments, Plan}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  test "empty attachments bypass unavailable requirements and produce no plan" do
    assert {:ok, nil} = Attachments.build_plan(outgoing([]), {:error, :capabilities_unavailable})
  end

  test "canonical builder and supplied resolver compose without modifying outgoing" do
    connection = %{id: 42, settings: %{"file_delivery" => %{"max_attachments_per_message" => 1}}}
    snapshot = snapshot()
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    incoming = %Incoming{content: "question", channel_id: "room", provider: :test}

    outgoing =
      Outgoing.from_pipeline_result(incoming, %{answer: "answer", attachments: files([2, 3])})

    assert {:ok, %Plan{} = plan} = Attachments.build_plan(outgoing, requirements)
    assert Enum.map(plan.groups, & &1.attachment_refs) == [[0], [1]]
    assert plan.requirements == requirements
    assert outgoing.attachments == files([2, 3])
    refute Map.has_key?(outgoing, :plan)
    refute Map.has_key?(plan, :attachments)
    refute Map.has_key?(plan, :prepared_steps)
  end

  test "resolution failures are returned unchanged without fallback or policy execution" do
    failures = [
      {nil, %{}},
      {%{resolved: %{file: false}}, %{}},
      {%{resolved: %{file: :native}}, %{}},
      {put_in(snapshot(), [:file_delivery, :transfer_mode], :unresolved), %{}},
      {snapshot(), %{settings: %{"file_delivery" => %{"max_attachments_per_message" => 0}}}},
      {put_in(
         snapshot(),
         [:file_delivery, :limits, :max_attachments_per_message, :value],
         :unresolved
       ), %{}}
    ]

    for {snapshot, connection} <- failures do
      assert {:error, _} = error = TransportRequirements.resolve(snapshot, connection)
      assert Attachments.build_plan(outgoing(files([1])), error) == error
    end
  end

  test "metadata planning ignores bytes and does not redeem handles" do
    records = [
      %Record{id: "lazy", kind: :file, size: nil, materialization_handle: "invalid-handle"},
      %Record{
        id: "encoded",
        kind: :file,
        size: 1,
        content: "INVALID BASE64",
        attributes: %{"encoding" => "base64"}
      }
    ]

    assert {:ok, plan} = Attachments.build_plan(outgoing(records), requirements())
    assert [%{attachment_refs: [0, 1]}] = plan.groups
    refute_received _
  end

  test "known aggregate and upload limits pack ordered fixed groups and steps" do
    requirements = requirements(max_attachment_bytes_per_message: 6, max_upload_request_bytes: 4)
    assert {:ok, plan} = Attachments.build_plan(outgoing(files([3, 3, 2])), requirements)
    assert plan.groups == [%{id: 0, attachment_refs: [0, 1]}, %{id: 1, attachment_refs: [2]}]

    assert plan.steps == [
             %Step{id: {:upload, 0, 0}, operation: :upload, group_id: 0, attachment_refs: [0]},
             %Step{id: {:upload, 0, 1}, operation: :upload, group_id: 0, attachment_refs: [1]},
             %Step{
               id: {:send, 0},
               operation: :send,
               group_id: 0,
               attachment_refs: [0, 1],
               depends_on: [{:upload, 0, 0}, {:upload, 0, 1}]
             },
             %Step{id: {:upload, 1, 0}, operation: :upload, group_id: 1, attachment_refs: [2]},
             %Step{
               id: {:send, 1},
               operation: :send,
               group_id: 1,
               attachment_refs: [2],
               depends_on: [{:upload, 1, 0}]
             }
           ]
  end

  test "direct sends have no upload dependencies and preserve explicit thread capability" do
    assert {:ok, plan} =
             Attachments.build_plan(
               outgoing(files([2])),
               requirements(transfer_mode: :send_with_attachments, supports_threads: true)
             )

    assert [%Step{operation: :send, depends_on: []}] = plan.steps
    assert plan.placement == :threaded

    assert {:ok, independent} =
             Attachments.build_plan(%{outgoing(files([2])) | thread_id: "thread"}, requirements())

    assert independent.placement == :independent
  end

  test "editing an existing message requires explicit attachment edit support" do
    for supported <- [false, true] do
      assert {:ok, plan} =
               Attachments.build_plan(
                 outgoing(files([1, 2])),
                 requirements(
                   max_attachments_per_message: 1,
                   supports_attachment_edits: supported
                 ),
                 "existing"
               )

      [first, second] = Enum.filter(plan.steps, &(&1.operation != :upload))
      assert first.operation == if(supported, do: :edit, else: :send)
      assert first.message_ref == if(supported, do: {:existing, "existing"}, else: nil)
      assert second.operation == :send
      assert second.message_ref == nil
    end
  end

  test "unknown limits remain distinct from inapplicable and positive limits" do
    for limit <- [:unresolved, :not_applicable, 10] do
      requirements = requirements(max_attachment_bytes: limit)
      assert {:ok, plan} = Attachments.build_plan(outgoing(files([nil, 9])), requirements)
      assert plan.requirements.max_attachment_bytes == limit
      assert [%{attachment_refs: [0, 1]}] = plan.groups
    end
  end

  test "known per-file lower bounds reject an oversized attachment at its original index" do
    for {field, reason} <- [
          max_attachment_bytes: :file_too_large,
          max_attachment_bytes_per_message: :message_too_large,
          max_encoded_message_bytes: :message_too_large,
          max_upload_request_bytes: :upload_request_too_large
        ] do
      assert {:error, {:attachment_limit_exceeded, 1, ^reason}} =
               Attachments.build_plan(
                 outgoing(files([1, 4])),
                 requirements([
                   {field, 3},
                   {:transfer_mode,
                    if(field == :max_encoded_message_bytes,
                      do: :send_with_attachments,
                      else: :upload_then_publish
                    )}
                 ])
               )
    end
  end

  test "uploaded file bytes do not bound the encoded message that publishes references" do
    requirements = requirements(max_encoded_message_bytes: 5, max_upload_request_bytes: 20)
    assert {:ok, plan} = Attachments.build_plan(outgoing(files([10, 10])), requirements)
    assert [%{attachment_refs: [0, 1]}] = plan.groups
    assert :ok = Attachments.validate_group([%{size: 10}, %{size: 10}], requirements)

    assert {:error, {:attachment_limit_exceeded, 0, :message_too_large}} =
             Attachments.build_plan(outgoing(files([10])), %{
               requirements
               | transfer_mode: :send_with_attachments
             })
  end

  test "invalid metadata rejects the whole plan without shifting later indices" do
    for record <- [
          nil,
          %{},
          %{file() | id: ""},
          %{file() | kind: :folder},
          %{file() | size: -1},
          %{file() | size: "1"},
          %{file() | attributes: nil}
        ] do
      assert {:error, {:invalid_attachment, 1, :invalid_attachment}} =
               Attachments.build_plan(outgoing([file(), record, file()]), requirements())
    end

    for record <- [
          %{file() | name: "../bad"},
          %{file() | name: "bad\r\nname"},
          %{file() | mime_type: "text/plain\r\nInjected: yes"}
        ] do
      assert {:error, {:invalid_attachment, 1, :invalid_attachment_metadata}} =
               Attachments.build_plan(outgoing([file(), record]), requirements())
    end
  end

  test "invalid requirements and payload shapes fail without crashing" do
    for invalid <- [
          nil,
          %{},
          requirements(max_attachments_per_message: 0),
          requirements(max_attachment_bytes: 0),
          requirements(transfer_mode: :unresolved)
        ] do
      assert {:error, :invalid_requirements} = Attachments.build_plan(outgoing([file()]), invalid)
    end

    assert {:error, :invalid_attachments} = Attachments.build_plan(outgoing(nil), requirements())

    assert {:error, :invalid_postable} =
             Attachments.build_plan(%{outgoing([file()]) | body: nil}, requirements())
  end

  property "packing preserves every original index exactly once and respects known ceilings" do
    check all(
            sizes <- list_of(integer(0..10), min_length: 1, max_length: 25),
            count <- integer(1..5),
            ceiling <- integer(10..30)
          ) do
      records = files(sizes)

      requirements =
        requirements(
          max_attachments_per_message: count,
          max_attachment_bytes_per_message: ceiling
        )

      assert {:ok, plan} = Attachments.build_plan(outgoing(records), requirements)
      assert :ok = Plan.validate(plan, length(records))

      assert Enum.flat_map(plan.groups, & &1.attachment_refs) ==
               Enum.to_list(0..(length(sizes) - 1))

      for group <- plan.groups do
        assert length(group.attachment_refs) <= count
        assert Enum.sum(Enum.map(group.attachment_refs, &Enum.at(sizes, &1))) <= ceiling
      end
    end
  end

  property "unknown sizes and byte ceilings preserve ordering without becoming known unlimited" do
    check all(
            sizes <-
              list_of(one_of([integer(0..10), constant(nil)]), min_length: 1, max_length: 20),
            count <- integer(1..4)
          ) do
      requirements = requirements(max_attachments_per_message: count)
      assert {:ok, plan} = Attachments.build_plan(outgoing(files(sizes)), requirements)
      assert plan.requirements.max_attachment_bytes == :unresolved

      assert Enum.flat_map(plan.groups, & &1.attachment_refs) ==
               Enum.to_list(0..(length(sizes) - 1))

      assert Enum.all?(plan.groups, &(length(&1.attachment_refs) <= count))
    end
  end

  defp snapshot do
    %{
      resolved: %{file: :native},
      file_delivery: %{
        transfer_mode: :upload_then_publish,
        limits: %{max_attachments_per_message: %{value: 3, configurable: true, required: true}}
      }
    }
  end

  defp requirements(overrides \\ []),
    do:
      struct!(
        TransportRequirements,
        Keyword.merge(
          [transfer_mode: :upload_then_publish, max_attachments_per_message: 3],
          overrides
        )
      )

  defp outgoing(records),
    do: %Outgoing{body: "answer", channel_id: "room", provider: :test, attachments: records}

  defp file,
    do: %Record{id: "repeated-id", kind: :file, name: "file.txt", mime_type: "text/plain"}

  defp files(sizes), do: Enum.map(sizes, &%{file() | size: &1})
end
