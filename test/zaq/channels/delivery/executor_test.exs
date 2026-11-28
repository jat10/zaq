defmodule Zaq.Channels.Delivery.ExecutorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Attachments, Error, Executor, Result}
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Test.DeliveryExecutionBridge, as: Bridge

  test "abort completes uploads before sequential publication and preserves plan order" do
    {outgoing, plan} = inputs(3, failure_policy: :abort)
    assert {:ok, result} = execute(outgoing, plan)
    assert Enum.map(result.steps, & &1.step.id) == Enum.map(plan.steps, & &1.id)

    for index <- 0..2, do: assert_receive({:operation, {:upload, ^index, 0}, _, _})
    for index <- 0..2, do: assert_receive({:operation, {:send, ^index}, _, _})
    assert length(Result.confirmed_receipts(result)) == 3
    refute_received {:operation, _, _, _}
  end

  test "later upload rejection under abort publishes nothing and retains uploaded-only evidence" do
    {outgoing, plan} = inputs(2, failure_policy: :abort)
    connection = %{owner: self(), responses: %{{:upload, 1, 0} => :rejected}}
    assert {:error, %Error{outcome: :failed}, result} = execute(outgoing, plan, connection)
    assert hd(result.steps).uploaded_refs == %{0 => "file-0"}
    assert Result.confirmed_receipts(result) == []
    refute_received {:operation, {:send, _}, _, _}
  end

  for mode <- [:send_with_attachments, :upload_then_publish] do
    @mode mode
    test "abort preparation failure in a later #{@mode} group publishes nothing" do
      {outgoing, plan} =
        inputs(2,
          transfer_mode: @mode,
          failure_policy: :abort,
          max_encoded_message_bytes: 20
        )

      records = [file("a"), %{file(String.duplicate("b", 15)) | size: 1}]
      outgoing = %{outgoing | attachments: records}
      assert {:error, %Error{stage: :preparation}, result} = execute(outgoing, plan)
      assert result.failures != []

      if @mode == :upload_then_publish do
        for index <- 0..1, do: assert_receive({:operation, {:upload, ^index, 0}, _, _})

        assert Enum.flat_map(result.steps, &Map.to_list(Map.get(&1, :uploaded_refs, %{}))) ==
                 [{0, "file-0"}, {1, "file-1"}]
      end

      assert Result.confirmed_receipts(result) == []
      assert {:ok, %{parts: parts, confirmed_message_count: 0}} = Result.safe_evidence(result)
      assert Enum.any?(parts, &(&1.reason == :size_limit))
      refute_received {:operation, _, _, _}
    end
  end

  test "abort retains earlier confirmation and never publishes after rejection" do
    {outgoing, plan} = inputs(3, transfer_mode: :send_with_attachments, failure_policy: :abort)

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:send, 1} => :rejected}})

    assert [%{message_id: "message-0"}] = Result.confirmed_receipts(result)
    assert_receive {:operation, {:send, 0}, _, _}
    assert_receive {:operation, {:send, 1}, _, _}
    refute_received {:operation, {:send, 2}, _, _}
  end

  test "independent abort keeps continuation text after earlier bytes are released" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments, failure_policy: :abort)
    assert {:ok, _} = execute(outgoing, plan)
    assert_receive {:operation, {:send, 0}, _, %{outgoing: %{body: "answer", thread_id: nil}}}

    assert_receive {:operation, {:send, 1}, _,
                    %{outgoing: %{body: "Additional files (2/2).", thread_id: nil}}}
  end

  test "continue promotes the next threaded root with the original answer" do
    {outgoing, plan} = inputs(3, transfer_mode: :send_with_attachments, supports_threads: true)

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:send, 0} => :unknown}})

    assert_receive {:operation, {:send, 0}, _, %{outgoing: %{body: "answer", thread_id: nil}}}
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "answer", thread_id: nil}}}

    assert_receive {:operation, {:send, 2}, _,
                    %{outgoing: %{body: "Additional files (3/3).", thread_id: "message-1"}}}

    assert Enum.map(result.steps, & &1.outcome) == [:unconfirmed, :confirmed, :confirmed]
    refute_received {:operation, _, _, _}
  end

  test "an uncertain existing edit is never repeated when promoting a later root" do
    {outgoing, _} =
      inputs(2,
        transfer_mode: :send_with_attachments,
        supports_threads: true,
        supports_attachment_edits: true
      )

    requirements = %TransportRequirements{
      transfer_mode: :send_with_attachments,
      max_attachments_per_message: 1,
      supports_threads: true,
      supports_attachment_edits: true
    }

    {:ok, plan} = Attachments.build_plan(outgoing, requirements, "streamed")

    assert {:ok, _} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:edit, 0} => :unknown}})

    assert_receive {:operation, {:edit, 0}, _, _}
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "answer"}}}
    refute_received {:operation, _, _, _}
  end

  test "independent ready messages overlap within the configured bound without a root" do
    {outgoing, plan} = inputs(4, transfer_mode: :send_with_attachments)
    connection = %{owner: self(), responses: Map.new(0..3, &{{:send, &1}, :wait})}
    task = Task.async(fn -> execute(outgoing, plan, connection, max_concurrency: 2) end)
    assert_receive {:operation, {:send, 0}, first, _}
    assert_receive {:operation, {:send, 1}, second, _}
    refute_received {:operation, {:send, 2}, _, _}
    send(second, {:resolve, confirmed("second")})
    assert_receive {:operation, {:send, 2}, third, _}
    send(third, {:resolve, confirmed("third")})
    assert_receive {:operation, {:send, 3}, fourth, _}
    send(fourth, {:resolve, confirmed("fourth")})
    send(first, {:resolve, confirmed("first")})
    assert {:ok, result} = Task.await(task)

    assert Enum.map(Result.confirmed_receipts(result), & &1.message_id) == [
             "first",
             "second",
             "third",
             "fourth"
           ]
  end

  test "threaded ready replies overlap only after a confirmed root" do
    {outgoing, plan} = inputs(3, transfer_mode: :send_with_attachments, supports_threads: true)
    connection = %{owner: self(), responses: Map.new(0..2, &{{:send, &1}, :wait})}
    task = Task.async(fn -> execute(outgoing, plan, connection) end)
    assert_receive {:operation, {:send, 0}, root, _}
    refute_received {:operation, {:send, 1}, _, _}
    send(root, {:resolve, confirmed("root")})
    assert_receive {:operation, {:send, 1}, left, %{outgoing: %{thread_id: "root"}}}
    assert_receive {:operation, {:send, 2}, right, %{outgoing: %{thread_id: "root"}}}
    send(left, {:resolve, confirmed("left")})
    send(right, {:resolve, confirmed("right")})
    assert {:ok, _} = Task.await(task)
  end

  test "sole send, edit and upload deadlines remain unconfirmed and never retry" do
    for operation <- [:send, :edit, :upload] do
      mode = if operation == :upload, do: :upload_then_publish, else: :send_with_attachments

      {outgoing, plan} =
        inputs(1,
          transfer_mode: mode,
          failure_policy: :abort,
          supports_attachment_edits: operation == :edit
        )

      plan =
        if operation == :edit do
          {:ok, edited} = Attachments.build_plan(outgoing, plan.requirements, "streamed")
          edited
        else
          plan
        end

      id = if operation == :upload, do: {:upload, 0, 0}, else: {operation, 0}

      assert {:error, %Error{outcome: :unconfirmed, reason: :timeout}, result} =
               execute(outgoing, plan, %{owner: self(), responses: %{id => :wait}},
                 step_timeout_ms: 20
               )

      assert_receive {:operation, ^id, worker, _}
      refute Process.alive?(worker)
      assert Enum.any?(result.steps, &(&1.outcome == :unconfirmed))
      refute_received {:operation, _, _, _}
    end
  end

  test "worker exit remains unknown and a later threaded root can still confirm" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments, supports_threads: true)

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:send, 0} => :crash}})

    assert [%{outcome: :unconfirmed, error: %Error{reason: :unknown}}, %{outcome: :confirmed}] =
             result.steps

    assert_receive {:operation, {:send, 0}, _, _}
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "answer"}}}
  end

  test "partial upload publishes only attested provider IDs and retains missing-file facts" do
    {outgoing, _} = inputs(2)

    requirements = %TransportRequirements{
      transfer_mode: :upload_then_publish,
      max_attachments_per_message: 2
    }

    {:ok, plan} = Attachments.build_plan(outgoing, requirements)

    partial =
      {:error, %Error{stage: :upload, outcome: :failed, reason: :rejected},
       %{uploaded_refs: %{0 => "real-id"}}}

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:upload, 0, 0} => partial}})

    assert_receive {:operation, {:send, 0}, _,
                    %{attachments: [%{index: 0, reference: "real-id"}]}}

    assert {:ok, evidence} = Result.safe_evidence(result)
    assert evidence.confirmed_attachment_count == 1
    assert [%{attachment_refs: [1], outcome: :failed}] = evidence.parts
  end

  test "continue without prepared files publishes the original answer once and retains failures" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments)
    outgoing = %{outgoing | attachments: [file(nil), file(nil)]}
    assert {:ok, result} = execute(outgoing, plan)
    assert_receive {:operation, {:send, _}, _, %{outgoing: %{body: "answer"}, attachments: []}}
    refute_received {:operation, _, _, _}
    assert length(result.failures) == 2
    assert {:ok, %{confirmed_attachment_count: 0}} = Result.safe_evidence(result)
  end

  test "invalid dependencies and indices fail before preparation or operations" do
    {outgoing, plan} = inputs(1)
    [upload, publication] = plan.steps
    invalid = %{plan | steps: [%{upload | depends_on: [publication.id]}, publication]}
    assert {:error, %Error{reason: :invalid_plan}} = execute(outgoing, invalid)
    refute_received {:prepared_upload, _}
    refute_received {:operation, _, _, _}
  end

  test "requirements failure uses selected explicit false policy or bounded text-only continuation" do
    {outgoing, _plan} = inputs(2)
    failure = {:error, :capabilities_unavailable}
    abort = %{owner: self(), settings: %{"file_delivery" => %{"send_on_file_failure" => false}}}

    assert {:error, %Error{reason: :missing_configuration}, _} =
             execute(outgoing, failure, abort, max_text_request_bytes: 100)

    refute_received {:operation, _, _, _}

    assert {:ok, result} =
             execute(outgoing, failure, %{owner: self()}, max_text_request_bytes: 100)

    assert_receive {:operation, {:send, 0}, _,
                    %{attachments: [], outgoing: %{body: "answer", attachments: []}}}

    refute_received {:prepared_upload, _}
    assert Enum.map(result.failures, & &1.attachment_refs) == [[0], [1]]

    assert {:error, %Error{}, _} =
             execute(outgoing, failure, %{owner: self()}, max_text_request_bytes: 2)

    refute_received {:operation, _, _, _}
  end

  test "a timed-out upload does not block a later usable group or fabricate a file ID" do
    {outgoing, plan} = inputs(2, supports_threads: true)

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:upload, 0, 0} => :wait}},
               step_timeout_ms: 20
             )

    assert_receive {:operation, {:upload, 0, 0}, _, _}
    assert_receive {:operation, {:upload, 1, 0}, _, _}

    assert_receive {:operation, {:send, 1}, _,
                    %{
                      outgoing: %{body: "answer"},
                      attachments: [%{index: 1, reference: "file-1"}]
                    }}

    refute_received {:operation, {:send, 0}, _, _}
    assert {:ok, %{confirmed_attachment_count: 1}} = Result.safe_evidence(result)
  end

  test "independent delivery retains the original answer after a preparation omission" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments)
    outgoing = %{outgoing | attachments: [file(nil), file("usable")]}
    assert {:ok, _result} = execute(outgoing, plan)
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "answer"}}}
    refute_received {:operation, {:send, 0}, _, _}
  end

  test "independent encoding failure transfers the answer to the next prepared group" do
    {outgoing, plan} =
      inputs(3, transfer_mode: :send_with_attachments, max_encoded_message_bytes: 25)

    outgoing = %{outgoing | attachments: [file(String.duplicate("x", 24)), file("y"), file("z")]}
    assert {:ok, result} = execute(outgoing, plan)
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "answer", thread_id: nil}}}

    assert_receive {:operation, {:send, 2}, _,
                    %{outgoing: %{body: "Additional files (3/3).", thread_id: nil}}}

    refute_received {:operation, _, _, _}
    assert {:ok, %{confirmed_attachment_count: 2, parts: parts}} = Result.safe_evidence(result)
    assert Enum.any?(parts, &(&1.group_id == 0 and &1.reason == :size_limit))
  end

  test "independent answer transfer revalidates each full request before text fallback" do
    {outgoing, plan} =
      inputs(2, transfer_mode: :send_with_attachments, max_encoded_message_bytes: 25)

    outgoing = %{
      outgoing
      | body: String.duplicate("a", 24),
        attachments: [file("xx"), file("yy")]
    }

    assert {:ok, result} = execute(outgoing, plan)
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: body}, attachments: []}}
    assert body == outgoing.body
    refute_received {:operation, _, _, _}
    assert {:ok, %{confirmed_attachment_count: 0, parts: parts}} = Result.safe_evidence(result)

    for index <- 0..1,
        do:
          assert(Enum.any?(parts, &(&1.attachment_refs == [index] and &1.reason == :size_limit)))

    assert {:error, %Error{reason: :size_limit}, _} =
             execute(%{outgoing | body: String.duplicate("a", 26)}, plan)

    refute_received {:operation, _, _, _}
  end

  test "independent provider uncertainty does not transfer or retry a prepared answer" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments)

    assert {:ok, _} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:send, 0} => :unknown}})

    assert_receive {:operation, {:send, 0}, _, %{outgoing: %{body: "answer"}}}
    assert_receive {:operation, {:send, 1}, _, %{outgoing: %{body: "Additional files (2/2)."}}}
    refute_received {:operation, _, _, _}
  end

  test "independent preparation omissions do not duplicate a reserved answer" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments)
    outgoing = %{outgoing | attachments: [file("usable"), file(nil)]}
    assert {:ok, _} = execute(outgoing, plan)
    assert_receive {:operation, {:send, 0}, _, %{outgoing: %{body: "answer"}}}
    refute_received {:operation, _, _, _}
  end

  for mode <- [:send_with_attachments, :upload_then_publish] do
    @mode mode
    test "changed confirmed-root headers can halt #{@mode} abort after earlier confirmation" do
      {outgoing, plan} =
        inputs(2,
          transfer_mode: @mode,
          supports_threads: true,
          failure_policy: :abort,
          max_encoded_message_bytes: 25
        )

      assert {:ok, result} = execute(outgoing, plan)
      assert [%{message_id: "message-0"}] = Result.confirmed_receipts(result)
      assert_receive {:operation, {:send, 0}, _, _}
      refute_received {:operation, {:send, 1}, _, _}
      assert [%{error: %Error{reason: :size_limit}}] = result.failures
    end
  end

  test "a sole reply after the root still observes its deadline" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments, supports_threads: true)

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:send, 1} => :wait}},
               step_timeout_ms: 20
             )

    assert [%{outcome: :confirmed}, %{outcome: :unconfirmed, error: %Error{reason: :timeout}}] =
             result.steps

    assert_receive {:operation, {:send, 0}, _, _}
    assert_receive {:operation, {:send, 1}, _, _}
    refute_received {:operation, _, _, _}
  end

  test "all uncertain candidates retain evidence without any retry" do
    {outgoing, plan} = inputs(2, transfer_mode: :send_with_attachments, supports_threads: true)

    assert {:error, %Error{outcome: :unconfirmed}, result} =
             execute(outgoing, plan, %{
               owner: self(),
               responses: %{{:send, 0} => :unknown, {:send, 1} => :unknown}
             })

    assert Enum.all?(result.steps, &(&1.outcome == :unconfirmed))
    assert_receive {:operation, {:send, 0}, _, _}
    assert_receive {:operation, {:send, 1}, _, _}
    refute_received {:operation, _, _, _}
  end

  test "malformed upload IDs remain uncertain and never become delivered attachments" do
    {outgoing, plan} = inputs(1)
    response = {:ok, %{uploaded_refs: %{0 => nil, 99 => "foreign"}}}

    assert {:ok, result} =
             execute(outgoing, plan, %{owner: self(), responses: %{{:upload, 0, 0} => response}})

    assert_receive {:operation, {:send, 0}, _, %{attachments: [], outgoing: %{body: "answer"}}}
    assert {:ok, %{confirmed_attachment_count: 0}} = Result.safe_evidence(result)
    assert hd(result.steps).outcome == :unconfirmed
  end

  test "failed upload dependencies prevent dependent uploads before effects" do
    {outgoing, plan} = inputs(2)
    [first, publication, second, last] = plan.steps
    plan = %{plan | steps: [first, publication, %{second | depends_on: [first.id]}, last]}

    assert {:ok, _result} =
             execute(outgoing, plan, %{owner: self(), responses: %{first.id => :unknown}})

    assert_receive {:operation, {:upload, 0, 0}, _, _}
    refute_received {:operation, {:upload, 1, 0}, _, _}
  end

  property "every metadata step executes at most once and results preserve original indices" do
    check all(
            count <- integer(1..8),
            mode <- member_of([:upload_then_publish, :send_with_attachments]),
            policy <- member_of([:abort, :continue])
          ) do
      {outgoing, plan} = inputs(count, transfer_mode: mode, failure_policy: policy)
      assert {:ok, result} = execute(outgoing, plan)

      ids =
        for _step <- plan.steps do
          assert_receive {:operation, id, _, _}
          id
        end

      assert MapSet.size(MapSet.new(ids)) == length(plan.steps)
      assert Enum.map(result.steps, & &1.step.id) == Enum.map(plan.steps, & &1.id)
      assert {:ok, %{confirmed_attachment_count: ^count}} = Result.safe_evidence(result)
      refute_received {:operation, _, _, _}
    end
  end

  defp execute(outgoing, plan, connection \\ %{owner: self()}, opts \\ []),
    do:
      Executor.execute(
        outgoing,
        plan,
        Bridge,
        connection,
        Keyword.merge([step_timeout_ms: 1_000], opts)
      )

  defp confirmed(id), do: {:ok, %{confirmation: :confirmed, message_id: id}}

  defp file(content),
    do: %Record{
      id: "file",
      kind: :file,
      name: "file.txt",
      mime_type: "text/plain",
      size: if(is_binary(content), do: byte_size(content)),
      content: content
    }

  defp inputs(count, overrides \\ []) do
    outgoing = %Outgoing{
      body: "answer",
      provider: :test,
      channel_id: "room",
      attachments: for(_ <- 1..count, do: file("x"))
    }

    requirements =
      struct!(
        TransportRequirements,
        Keyword.merge(
          [transfer_mode: :upload_then_publish, max_attachments_per_message: 1],
          overrides
        )
      )

    {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    {outgoing, plan}
  end
end
