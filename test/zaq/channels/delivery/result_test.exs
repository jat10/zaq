defmodule Zaq.Channels.Delivery.ResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.{Error, Plan, Result}
  alias Zaq.Channels.Delivery.Plan.Step
  alias Zaq.Channels.TransportRequirements

  @attempt_id "fbb6ea38-45d4-40d2-8135-9ecfd53efcbb"

  test "results retain plan order and distinguish uploads from confirmed publications" do
    plan = plan()
    receipt = %{confirmation: :confirmed, message_id: "confirmed", private_response: "private"}

    outcomes = %{
      {:send, 0} => %{outcome: :confirmed, receipt: receipt, delivered_attachment_refs: [0]},
      {:upload, 0, 0} => %{outcome: :uploaded, uploaded_refs: %{0 => "provider-file"}}
    }

    result = Result.new(plan, outcomes, @attempt_id)
    assert Enum.map(result.steps, & &1.step.id) == [{:upload, 0, 0}, {:send, 0}]
    assert Result.confirmed_receipts(result) == [receipt]
    assert {:ok, evidence} = Result.safe_evidence(result)
    assert evidence.confirmed_message_count == 1
    assert evidence.confirmed_attachment_count == 1
    assert evidence.parts == []
    refute Jason.encode!(evidence) =~ "provider-file"
    refute Jason.encode!(evidence) =~ "private"
  end

  test "uploaded-only files remain private facts beside an unattempted publication" do
    result =
      Result.new(
        plan(),
        %{{:upload, 0, 0} => %{outcome: :uploaded, uploaded_refs: %{0 => "uploaded-only"}}},
        @attempt_id
      )

    assert Result.confirmed_receipts(result) == []
    assert {:ok, evidence} = Result.safe_evidence(result)
    assert evidence.confirmed_message_count == 0
    assert evidence.confirmed_attachment_count == 0

    assert [%{step_id: [:send, 0], outcome: :unattempted, attachment_refs: [0, 1]}] =
             evidence.parts

    assert hd(result.steps).uploaded_refs == %{0 => "uploaded-only"}
  end

  test "confirmed text fallback retains failed file facts without confirming discarded files" do
    failure = %{
      group_id: 0,
      attachment_refs: [1],
      error: error(:preparation, :failed, :size_limit)
    }

    result =
      Result.new(
        plan(:send_with_attachments),
        %{{:send, 0} => %{outcome: :confirmed, receipt: %{confirmation: :confirmed}}},
        @attempt_id,
        [failure]
      )

    assert {:ok, evidence} = Result.safe_evidence(result)
    assert evidence.confirmed_message_count == 1
    assert evidence.confirmed_attachment_count == 0

    assert [%{stage: :preparation, outcome: :failed, reason: :size_limit, attachment_refs: [1]}] =
             evidence.parts
  end

  test "rejection, uncertain acceptance, and prior streamed edits remain distinct" do
    for {outcome, reason} <- [failed: :rejected, unconfirmed: :timeout] do
      plan = plan(:send_with_attachments)
      [publication] = plan.steps
      edit = %{publication | id: {:edit, 0}, operation: :edit, message_ref: {:existing, "prior"}}
      plan = %{plan | steps: [edit]}

      result =
        Result.new(
          plan,
          %{edit.id => %{outcome: outcome, error: error(:publication, outcome, reason)}},
          @attempt_id
        )

      assert {:ok, %{parts: [part]}} = Result.safe_evidence(result)
      assert part.outcome == outcome
      assert part.reason == reason
      assert part.step_id == [:edit, 0]
      refute Map.has_key?(part, :message_ref)
    end
  end

  test "configuration failures can be reported without acquiring or inventing a plan" do
    result = %Result{
      attempt_id: @attempt_id,
      steps: [],
      failures: [
        %{
          group_id: nil,
          attachment_refs: [2, 4],
          error: error(:configuration, :failed, :missing_configuration)
        }
      ]
    }

    assert {:ok, %{parts: [%{group_id: nil, attachment_refs: [2, 4], stage: :configuration}]}} =
             Result.safe_evidence(result)
  end

  test "safe evidence has explicit bounds and omitted counts" do
    failures =
      for group <- 0..129 do
        %{
          group_id: group,
          attachment_refs: Enum.to_list(0..129),
          error: error(:preparation, :failed, :size_limit)
        }
      end

    result = %Result{attempt_id: @attempt_id, steps: [], failures: failures}
    assert {:ok, evidence} = Result.safe_evidence(result)
    assert length(evidence.parts) == 128
    assert evidence.omitted_part_count == 2
    assert hd(evidence.parts).attachment_refs == Enum.to_list(0..127)
    assert hd(evidence.parts).omitted_attachment_count == 2
    assert length(result.failures) == 130
  end

  test "malformed evidence cannot become confirmation or expose arbitrary terms" do
    base = Result.new(plan(:send_with_attachments), %{}, @attempt_id)
    [part] = base.steps

    for malformed <- [
          %{base | attempt_id: "not-an-attempt"},
          %{base | steps: [%{part | outcome: :confirmed}]},
          %{base | steps: [%{part | step: %{part.step | id: {:secret, "provider-response"}}}]},
          %{base | steps: [%{part | step: %{part.step | attachment_refs: [-1]}}]},
          %{
            base
            | failures: [
                %{
                  group_id: 0,
                  attachment_refs: [0],
                  error: error(:publication, :failed, :timeout)
                }
              ]
          },
          %{
            base
            | failures: [
                %{
                  group_id: 0,
                  attachment_refs: [0],
                  error: error(:publication, :failed, "raw-secret")
                }
              ]
          }
        ] do
      assert {:error, :invalid_delivery_result} = Result.safe_evidence(malformed)
    end
  end

  property "raw transport causes never enter safe evidence or inspection" do
    check all(cause <- binary(min_length: 20, max_length: 100)) do
      failure = %Error{stage: :upload, outcome: :unconfirmed, reason: :unknown, cause: cause}

      result =
        Result.new(
          plan(),
          %{{:upload, 0, 0} => %{outcome: :unconfirmed, error: failure}},
          @attempt_id
        )

      assert {:ok, evidence} = Result.safe_evidence(result)
      assert {:ok, decoded} = Jason.decode(Jason.encode!(evidence))
      assert decoded["version"] == 1
      refute Map.has_key?(hd(evidence.parts), :cause)
      refute inspect(result) =~ inspect(cause)
      refute inspect(failure) =~ inspect(cause)
    end
  end

  test "uncertain operations cannot be relabeled as unattempted or preparation failures" do
    base = Result.new(plan(:send_with_attachments), %{}, @attempt_id)
    [part] = base.steps
    uncertain = error(:publication, :unconfirmed, :timeout)

    assert {:error, :invalid_delivery_result} =
             Result.safe_evidence(%{base | steps: [Map.put(part, :error, uncertain)]})

    assert {:error, :invalid_delivery_result} =
             Result.safe_evidence(%{
               base
               | failures: [%{group_id: 0, attachment_refs: [0], error: uncertain}]
             })
  end

  test "malformed uploaded IDs cannot suppress failed-file evidence" do
    for refs <- [%{0 => nil}, %{99 => "foreign"}, %{0 => ""}] do
      result =
        Result.new(
          plan(),
          %{
            {:upload, 0, 0} => %{
              outcome: :failed,
              error: error(:upload, :failed, :rejected),
              uploaded_refs: refs
            }
          },
          @attempt_id
        )

      assert {:error, :invalid_delivery_result} = Result.safe_evidence(result)
    end
  end

  property "mixed publication outcomes keep original indices and exact confirmation counts" do
    check all(
            statuses <-
              list_of(member_of([:confirmed, :failed, :unconfirmed]),
                min_length: 1,
                max_length: 20
              )
          ) do
      steps =
        statuses
        |> Enum.with_index()
        |> Enum.map(fn {_status, index} ->
          %Step{id: {:send, index}, operation: :send, group_id: index, attachment_refs: [index]}
        end)

      plan = %{
        plan(:send_with_attachments)
        | steps: steps,
          groups: Enum.map(steps, &%{id: &1.group_id, attachment_refs: &1.attachment_refs})
      }

      assert :ok = Plan.validate(plan, length(statuses))

      outcomes =
        statuses
        |> Enum.with_index()
        |> Enum.reverse()
        |> Map.new(fn
          {:confirmed, index} ->
            {{:send, index},
             %{
               outcome: :confirmed,
               receipt: %{confirmation: :confirmed},
               delivered_attachment_refs: [index]
             }}

          {:failed, index} ->
            {{:send, index}, %{outcome: :failed, error: error(:publication, :failed, :rejected)}}

          {:unconfirmed, index} ->
            {{:send, index},
             %{outcome: :unconfirmed, error: error(:publication, :unconfirmed, :timeout)}}
        end)

      result = Result.new(plan, outcomes, @attempt_id)
      assert Enum.map(result.steps, & &1.outcome) == statuses
      assert {:ok, evidence} = Result.safe_evidence(result)
      confirmed_count = Enum.count(statuses, &(&1 == :confirmed))
      assert evidence.confirmed_message_count == confirmed_count
      assert evidence.confirmed_attachment_count == confirmed_count

      expected_refs =
        statuses
        |> Enum.with_index()
        |> Enum.reject(fn {status, _index} -> status == :confirmed end)
        |> Enum.map(fn {_status, index} -> [index] end)

      assert Enum.map(evidence.parts, & &1.attachment_refs) == expected_refs
    end
  end

  defp error(stage, outcome, reason), do: %Error{stage: stage, outcome: outcome, reason: reason}

  defp plan(mode \\ :upload_then_publish) do
    upload = %Step{id: {:upload, 0, 0}, operation: :upload, group_id: 0, attachment_refs: [0, 1]}
    publication = %Step{id: {:send, 0}, operation: :send, group_id: 0, attachment_refs: [0, 1]}

    %Plan{
      requirements: %TransportRequirements{transfer_mode: mode, max_attachments_per_message: 2},
      placement: :independent,
      groups: [%{id: 0, attachment_refs: [0, 1]}],
      steps:
        if(mode == :upload_then_publish,
          do: [upload, %{publication | depends_on: [upload.id]}],
          else: [publication]
        )
    }
  end
end
