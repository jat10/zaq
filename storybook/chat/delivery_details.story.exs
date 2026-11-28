defmodule Storybook.Chat.DeliveryDetails do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.delivery_details/1

  def description, do: "Grouped unsuccessful parts in the existing delivery-details modal. Confirmed messages stay in normal history."

  def variations do
    [
      %Variation{id: :partial_success, description: "Confirmed answer with rejected and unconfirmed file parts",
        attributes: %{message: message(:partial, "Some delivery parts failed or remain unconfirmed.", [
          part("upload", 1, "unconfirmed", "timeout", [2, 3]),
          part("send", 2, "failed", "rejected", [4])])}},
      %Variation{id: :all_failed, description: "No confirmed publication",
        attributes: %{message: message(:failed, "The delivery attempt failed.", [
          part("send", 0, "failed", "rejected", [0, 1]),
          part("send", 1, "unattempted", "aborted", [2])])}},
      %Variation{id: :legacy, description: "Existing single-message uncertainty without grouped facts",
        attributes: %{message: message(:unconfirmed, "No definitive delivery outcome is recorded. The message may have been delivered.", [])}}
    ]
  end

  defp message(state, reason, parts), do: %{inserted_at: ~U[2026-11-28 09:30:00Z],
    delivery: %{state: state, reason: reason, parts: parts, omitted_part_count: 0}}

  defp part(operation, group, outcome, reason, refs), do: %{"operation" => operation,
    "group_id" => group, "outcome" => outcome, "reason" => reason,
    "stage" => if(operation == "upload", do: "upload", else: "publication"),
    "attachment_refs" => refs, "omitted_attachment_count" => 0}
end
