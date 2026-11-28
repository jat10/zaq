defmodule ZaqWeb.Components.GroupedDeliveryDetailsTest do
  use Zaq.DataCase, async: true
  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.ChatMessage

  test "one existing modal lists only unsuccessful parts and separates rejection from uncertainty" do
    message = %{
      inserted_at: ~U[2026-11-10 10:30:00Z],
      delivery: %{
        state: :partial,
        reason: "Some parts failed.",
        parts: [
          part(0, "failed", "rejected"),
          part(1, "unconfirmed", "timeout"),
          part(2, "unattempted", "dependency_failed")
        ],
        omitted_part_count: 2
      }
    }

    html = render_component(&ChatMessage.delivery_details/1, message: message)
    dom = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(dom, "#channel-delivery-details")) == 1
    assert Enum.count(LazyHTML.query(dom, "[data-testid='delivery-failed-part']")) == 3
    assert html =~ "Partially delivered"
    assert html =~ "Rejected"
    assert html =~ "Unconfirmed"
    assert html =~ "may have accepted"
    assert html =~ "Not attempted"
    assert html =~ "2 additional"
    refute html =~ "PRIVATE"
    assert html =~ "channel-delivery-details-focus"
    assert html =~ "close_delivery_info"
  end

  test "partial success keeps the normal answer bubble and adds the existing status affordance" do
    html =
      render_component(&ChatMessage.assistant_bubble/1, %{
        content: "**Delivered answer**",
        timestamp: ~U[2026-11-10 10:30:00Z],
        msg_id: "answer",
        delivery_state: :partial
      })

    dom = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(dom, "[data-testid='delivery-status']")) == 1
    assert LazyHTML.query(dom, ".zaq-chat-delivery") |> Enum.empty?()
    refute html =~ "zaq-chat-delivery-column"
    assert html =~ "<strong>Delivered answer</strong>"
    refute html =~ "Generated "
  end

  test "legacy empty details stay valid and text remains escaped" do
    message = %{
      inserted_at: ~U[2026-11-10 10:30:00Z],
      delivery: %{state: :unconfirmed, reason: "<script>unsafe</script>"}
    }

    html = render_component(&ChatMessage.delivery_details/1, message: message)
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    refute html =~ "delivery-failed-part"
  end

  defp part(group, outcome, reason),
    do: %{
      "group_id" => group,
      "operation" => "send",
      "stage" => "publication",
      "outcome" => outcome,
      "reason" => reason,
      "attachment_refs" => [group],
      "omitted_attachment_count" => 0,
      "cause" => "PRIVATE"
    }
end
