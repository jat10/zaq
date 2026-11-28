defmodule Zaq.Channels.Delivery.PreparationAttemptTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Mox

  alias Zaq.Channels.Delivery.{Attachments, Error, Preparation}
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Materialization
  alias Zaq.Test.DeliveryPreparationBridge, as: Bridge

  setup :verify_on_exit!

  test "successful signed acquisition is cached once across batches and group reads" do
    record = lazy_file()
    {outgoing, plan} = inputs([record], max_attachments_per_message: 1)

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{id: "owner"}
      refute event.opts[:skip_permissions]
      %{event | response: {:ok, %{record: file("bytes")}}}
    end)

    assert {:ok, attempt} = Preparation.start(outgoing, plan, context())
    assert {:ok, [%{index: 0, content: "bytes"}], attempt} = Preparation.acquire_group(attempt, 0)
    assert {:ok, [%{index: 0, content: "bytes"}], attempt} = Preparation.acquire_group(attempt, 0)
    assert attempt.records == %{}
    assert outgoing.attachments == [record]
    assert plan.groups == [%{id: 0, attachment_refs: [0]}]
  end

  test "denials are cached once and retain one safe failure" do
    {outgoing, plan} = inputs([lazy_file()])

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      %{event | response: {:error, :unauthorized}}
    end)

    assert {:ok, attempt} = Preparation.start(outgoing, plan, context())
    assert {:ok, [], attempt} = Preparation.acquire_group(attempt, 0)
    assert {:ok, [], attempt} = Preparation.acquire_group(attempt, 0)

    assert [%{attachment_refs: [0], error: %Error{outcome: :failed}}] =
             Preparation.failures(attempt)
  end

  test "continue retains usable original indices and abort fails before encoding or publication" do
    records = [file("ok"), %{file("%%%") | attributes: %{"encoding" => "base64"}}]

    for policy <- [:continue, :abort] do
      {outgoing, plan} = inputs(records, failure_policy: policy)
      assert {:ok, attempt} = Preparation.start(outgoing, plan)

      case policy do
        :continue ->
          assert {:ok, [%{index: 0}], attempt} = Preparation.acquire_group(attempt, 0)
          assert [%{attachment_refs: [1]}] = Preparation.failures(attempt)

        :abort ->
          assert {:error, %Error{stage: :preparation, outcome: :failed}, _attempt} =
                   Preparation.acquire_group(attempt, 0)
      end

      refute_received {:prepared_message, _, _, _}
      refute_received :unexpected_publication
    end
  end

  test "actual fixed-group growth fails without regrouping and preserves text fallback evidence" do
    {outgoing, plan} =
      inputs([%{file("four") | size: 1}, %{file("five!") | size: 1}],
        max_attachment_bytes_per_message: 8
      )

    assert {:ok, attempt} = Preparation.start(outgoing, plan)
    assert {:ok, [], attempt} = Preparation.acquire_group(attempt, 0)

    assert [%{attachment_refs: [0, 1], error: %Error{reason: :size_limit}}] =
             Preparation.failures(attempt)

    assert attempt.plan == plan
  end

  test "exact encoded request limits and malformed prepared maps reject before effects" do
    for {overrides, connection, expected} <- [
          {[max_encoded_message_bytes: 5], %{owner: self(), overhead: 2}, :size_limit},
          {[], %{owner: self(), invalid_payload?: true}, :preparation_failed}
        ] do
      {outgoing, plan} =
        inputs([file("a")], Keyword.put(overrides, :transfer_mode, :send_with_attachments))

      assert {:ok, attempt} = Preparation.start(outgoing, plan)
      assert {:ok, files, attempt} = Preparation.acquire_group(attempt, 0)

      assert {:error, %Error{reason: ^expected}, attempt} =
               Preparation.prepare_step(
                 attempt,
                 {:send, 0},
                 %{outgoing: outgoing, attachments: files},
                 Bridge,
                 connection
               )

      assert attempt.prepared == %{}
      refute_received :unexpected_publication
    end
  end

  test "upload batch limits use exact encoded size and fixed original batch references" do
    {outgoing, plan} = inputs([file("a"), file("b")], max_upload_request_bytes: 2)
    assert {:ok, attempt} = Preparation.start(outgoing, plan)
    assert {:ok, files, attempt} = Preparation.acquire_group(attempt, 0)

    assert {:error, %Error{reason: :size_limit}, _attempt} =
             Preparation.prepare_step(
               attempt,
               {:upload, 0, 0},
               %{outgoing: outgoing, attachments: files},
               Bridge,
               %{owner: self(), overhead: 1}
             )
  end

  test "changed thread headers are re-encoded and transient bytes live only through their consumers" do
    {outgoing, plan} = inputs([file("raw-bytes")], transfer_mode: :send_with_attachments)
    assert {:ok, attempt} = Preparation.start(outgoing, plan)
    assert {:ok, files, attempt} = Preparation.acquire_group(attempt, 0)

    assert {:ok, _, attempt} =
             Preparation.prepare_step(
               attempt,
               {:send, 0},
               %{outgoing: outgoing, attachments: files},
               Bridge,
               %{owner: self()}
             )

    changed = %{outgoing | thread_id: "confirmed-root", body: "continuation"}

    assert {:ok, _, attempt} =
             Preparation.prepare_step(
               attempt,
               {:send, 0},
               %{outgoing: changed, attachments: files},
               Bridge,
               %{owner: self()}
             )

    assert_receive {:prepared_message, "answer", nil, [0]}
    assert_receive {:prepared_message, "continuation", "confirmed-root", [0]}
    attempt = Preparation.release_step(attempt, {:send, 0})
    assert attempt.cache == %{0 => :released}
    assert attempt.prepared == %{}
    assert {:error, %Error{}, _} = Preparation.acquire_group(attempt, 0)
    closed = Preparation.close(attempt)
    assert closed.cache == %{}
    assert closed.records == %{}
    assert closed.context == %{}
  end

  test "upload bytes are released without waiting for publication and attempts stay isolated" do
    {outgoing, plan} = inputs([file("private")])
    assert {:ok, left} = Preparation.start(outgoing, plan)
    assert {:ok, right} = Preparation.start(outgoing, plan)
    assert {:ok, _, left} = Preparation.acquire_group(left, 0)
    left = Preparation.release_step(left, {:upload, 0, 0})
    assert left.cache == %{0 => :released}
    assert right.cache == %{}
    assert {:ok, [%{content: "private"}], _right} = Preparation.acquire_group(right, 0)
    refute inspect(left) =~ "private"
  end

  test "nil identity cannot redeem a handle through an attempt" do
    {outgoing, plan} = inputs([lazy_file()])

    assert {:ok, attempt} =
             Preparation.start(outgoing, plan, %{
               node_router: Zaq.NodeRouterMock,
               event_opts: [skip_permissions: true]
             })

    assert {:ok, [], attempt} = Preparation.acquire_group(attempt, 0)
    assert [%{error: %Error{cause: reason}}] = Preparation.failures(attempt)
    assert reason =~ "unauthorized_materialization_handle"
  end

  test "changed continuation headers are measured again before publication" do
    {outgoing, plan} =
      inputs([file("raw-bytes")],
        transfer_mode: :send_with_attachments,
        max_encoded_message_bytes: 20
      )

    assert {:ok, attempt} = Preparation.start(outgoing, plan)
    assert {:ok, files, attempt} = Preparation.acquire_group(attempt, 0)

    assert {:ok, %{size_bytes: 15}, attempt} =
             Preparation.prepare_step(
               attempt,
               {:send, 0},
               %{outgoing: outgoing, attachments: files},
               Bridge,
               %{owner: self()}
             )

    changed = %{outgoing | thread_id: "confirmed-root", body: "continuation"}

    assert {:error, %Error{reason: :size_limit}, attempt} =
             Preparation.prepare_step(
               attempt,
               {:send, 0},
               %{outgoing: changed, attachments: files},
               Bridge,
               %{owner: self()}
             )

    assert attempt.prepared == %{}
    refute_received :unexpected_publication
  end

  test "duplicate or foreign indices cannot enter an encoded request" do
    {outgoing, plan} = inputs([file("a")], transfer_mode: :send_with_attachments)
    assert {:ok, attempt} = Preparation.start(outgoing, plan)
    assert {:ok, [file], attempt} = Preparation.acquire_group(attempt, 0)

    for files <- [[file, file], [%{file | index: 99}]] do
      assert {:error, %Error{}, _} =
               Preparation.prepare_step(
                 attempt,
                 {:send, 0},
                 %{outgoing: outgoing, attachments: files},
                 Bridge,
                 %{owner: self()}
               )

      refute_received {:prepared_message, _, _, _}
    end
  end

  property "group acquisition preserves original indices and reuses each signed redemption" do
    check all(count <- integer(1..8), limit <- integer(1..4)) do
      records = for index <- 0..(count - 1), do: lazy_file("file-#{index}")
      {outgoing, plan} = inputs(records, max_attachments_per_message: limit)

      expect(Zaq.NodeRouterMock, :dispatch, count, fn event ->
        %{event | response: {:ok, %{record: file("decoded")}}}
      end)

      assert {:ok, attempt} = Preparation.start(outgoing, plan, context())

      {refs, _attempt} =
        Enum.reduce(plan.groups, {[], attempt}, fn group, {refs, attempt} ->
          assert {:ok, files, attempt} = Preparation.acquire_group(attempt, group.id)
          assert {:ok, ^files, attempt} = Preparation.acquire_group(attempt, group.id)
          {refs ++ Enum.map(files, & &1.index), attempt}
        end)

      assert refs == Enum.to_list(0..(count - 1))
      verify!()
    end
  end

  defp context, do: %{actor: %{id: "owner"}, node_router: Zaq.NodeRouterMock}

  defp lazy_file(id \\ "file") do
    {:ok, handle} =
      Materialization.issue("communication_media", %{
        "provider" => "mattermost",
        "reference" => id,
        "source_author_id" => "owner"
      })

    %{file(nil) | materialization_handle: handle}
  end

  defp file(content),
    do: %Record{
      id: "file",
      kind: :file,
      size: if(is_binary(content), do: byte_size(content)),
      name: "file.txt",
      mime_type: "text/plain",
      content: content
    }

  defp inputs(records, overrides \\ []) do
    outgoing = %Outgoing{
      body: "answer",
      provider: :test,
      channel_id: "room",
      attachments: records
    }

    requirements =
      struct!(
        TransportRequirements,
        Keyword.merge(
          [transfer_mode: :upload_then_publish, max_attachments_per_message: 3],
          overrides
        )
      )

    {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    {outgoing, plan}
  end
end
