defmodule Zaq.Channels.Delivery.EmailSizeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Channels.Delivery.{Attachments, Preparation}
  alias Zaq.Channels.EmailBridge.Attachment
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  setup :verify_on_exit!

  test "real MIME encoded size does not reject an attachment that fits after decoding" do
    record = email_record()
    assert record.size == 8
    assert record.content == nil
    assert record.attributes["encoding"] == "base64"
    requirements = requirements(max_attachment_bytes: 5)

    assert {:ok, plan} = Attachments.build_plan(outgoing([record]), requirements)
    assert [%{attachment_refs: [0]}] = plan.groups
    assert {:ok, acquired} = Preparation.acquire(%{record | content: "aGVsbG8="}, requirements)
    assert acquired.content == "hello"
    assert acquired.size == 5
    assert record.size == 8
  end

  test "persisted and hydrated email metadata retains encoded size semantics" do
    original = email_record()
    stored = original |> Record.attachment_metadata() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, hydrated} =
             CommunicationMedia.hydrate(stored, %{actor: %{id: "sender@example.com"}})

    assert hydrated.size == 8
    refute Map.has_key?(hydrated.attributes, "encoding")

    assert {:ok, plan} =
             Attachments.build_plan(outgoing([hydrated]), requirements(max_attachment_bytes: 5))

    assert [%{attachment_refs: [0]}] = plan.groups
  end

  test "metadata planning does not decode content or redeem a handle to learn raw size" do
    record = %{email_record() | content: "invalid base64", materialization_handle: "invalid"}

    assert {:ok, _} =
             Attachments.build_plan(outgoing([record]), requirements(max_attachment_bytes: 1))

    assert {:error, :invalid_attachment_base64} = Preparation.acquire(record, requirements())
    assert {:ok, _} = Attachments.build_plan(outgoing([%{record | content: nil}]), requirements())
    refute_received _
  end

  test "known raw sizes are preserved even when the content is base64" do
    for encoding <- ["base64", "binary", "utf-8"] do
      record = %Record{
        id: "raw-size",
        kind: :file,
        size: 6,
        attributes: %{"encoding" => encoding}
      }

      assert {:error, {:attachment_limit_exceeded, 1, :file_too_large}} =
               Attachments.build_plan(
                 outgoing([email_record(), record]),
                 requirements(max_attachment_bytes: 5)
               )
    end

    record = %Record{
      id: "decoded-size",
      kind: :file,
      size: 5,
      content: "aGVsbG8=",
      attributes: %{"encoding" => "base64"}
    }

    assert {:ok, _} =
             Attachments.build_plan(outgoing([record]), requirements(max_attachment_bytes: 5))

    assert {:ok, %{size: 5, content: "hello"}} =
             Preparation.acquire(record, requirements(max_attachment_bytes: 5))
  end

  test "encoded-only sizes do not force message or upload splits but known raw sizes do" do
    raw = %Record{id: "raw", kind: :file, size: 3}
    records = [raw, email_record(), raw]

    assert {:ok, plan} =
             Attachments.build_plan(
               outgoing(records),
               requirements(max_attachment_bytes_per_message: 5)
             )

    assert Enum.map(plan.groups, & &1.attachment_refs) == [[0, 1], [2]]

    assert {:ok, plan} =
             Attachments.build_plan(outgoing(records), requirements(max_upload_request_bytes: 5))

    assert [%{attachment_refs: [0, 1, 2]}] = plan.groups

    assert plan.steps |> Enum.filter(&(&1.operation == :upload)) |> Enum.map(& &1.attachment_refs) ==
             [[0, 1], [2]]

    assert {:ok, plan} =
             Attachments.build_plan(
               outgoing(records),
               requirements(transfer_mode: :send_with_attachments, max_encoded_message_bytes: 5)
             )

    assert Enum.map(plan.groups, & &1.attachment_refs) == [[0, 1], [2]]
  end

  test "actual acquired email bytes enforce single-file and fixed-group limits" do
    record = email_record()
    context = %{actor: %{id: "sender@example.com"}, node_router: Zaq.NodeRouterMock}

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn event ->
      assert event.opts[:action] == :materialize_record
      assert event.request["encoding"] == "base64"
      assert event.request["size"] == 8

      %{
        event
        | response:
            {:ok,
             %Record{
               id: record.id,
               kind: :file,
               content: "hello",
               size: 5,
               attributes: %{"encoding" => "binary"}
             }}
      }
    end)

    assert {:ok, acquired} =
             Preparation.acquire(record, requirements(max_attachment_bytes: 5), context)

    assert acquired.size == 5

    assert {:error, :file_too_large} =
             Preparation.acquire(record, requirements(max_attachment_bytes: 4), context)

    for {overrides, validator, error} <- [
          {[max_attachment_bytes_per_message: 9], &Attachments.validate_group/2,
           :message_too_large},
          {[max_upload_request_bytes: 9], &Attachments.validate_upload_group/2,
           :upload_request_too_large},
          {[transfer_mode: :send_with_attachments, max_encoded_message_bytes: 9],
           &Attachments.validate_group/2, :message_too_large}
        ] do
      requirements = requirements(overrides)
      assert {:ok, plan} = Attachments.build_plan(outgoing([record, record]), requirements)
      assert [%{attachment_refs: [0, 1]}] = plan.groups
      assert {:error, ^error} = validator.([acquired, acquired], requirements)
      assert [%{attachment_refs: [0, 1]}] = plan.groups
    end
  end

  property "MIME encoded-size metadata cannot reject unknown raw sizes or change input ordering" do
    check all(
            sizes <- list_of(integer(1..1_000_000), min_length: 1, max_length: 12),
            count <- integer(1..4)
          ) do
      records = Enum.map(sizes, &email_record(%{encoded_size: &1}))

      requirements =
        requirements(
          max_attachments_per_message: count,
          max_attachment_bytes: 1,
          max_attachment_bytes_per_message: 1,
          max_upload_request_bytes: 1
        )

      assert {:ok, plan} = Attachments.build_plan(outgoing(records), requirements)

      assert Enum.flat_map(plan.groups, & &1.attachment_refs) ==
               Enum.to_list(0..(length(records) - 1))

      assert Enum.all?(plan.groups, &(length(&1.attachment_refs) <= count))
      assert Enum.map(records, & &1.size) == sizes
    end
  end

  test "other MIME transfer encodings also leave raw size unknown" do
    for encoding <- ["quoted-printable", "7bit", "8bit", "binary"] do
      record = email_record(%{encoding: encoding})

      assert {:ok, _} =
               Attachments.build_plan(outgoing([record]), requirements(max_attachment_bytes: 1))

      assert record.size == 8
    end
  end

  defp email_record(overrides \\ %{}) do
    Attachment.to_record(
      Map.merge(
        %{
          section: "2",
          filename: "hello.txt",
          content_type: "text/plain",
          encoding: "base64",
          encoded_size: 8,
          disposition: "attachment"
        },
        overrides
      ),
      %{
        channel_config_id: 3,
        mailbox: "INBOX",
        uid_validity: 12,
        uid: 34,
        source_author_id: "sender@example.com"
      }
    )
  end

  defp outgoing(records),
    do: %Outgoing{body: "answer", provider: :test, channel_id: "room", attachments: records}

  defp requirements(overrides \\ []),
    do:
      struct!(
        TransportRequirements,
        Keyword.merge(
          [transfer_mode: :upload_then_publish, max_attachments_per_message: 3],
          overrides
        )
      )
end
