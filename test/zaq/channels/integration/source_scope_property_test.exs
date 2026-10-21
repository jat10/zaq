defmodule Zaq.Channels.Integration.SourceScopePropertyTest do
  use Zaq.TestSupport.Channels.Integration.Case
  use ExUnitProperties

  alias Zaq.Engine.Conversations.TranscriptMessage

  property "native id replay is stable within a scope and distinct across connector scopes" do
    first = channel_session(:mattermost)
    second = channel_session(:mattermost)

    check all(id <- string(?a..?z, length: 26), max_runs: 15) do
      emitted =
        emit_message(first, :shared, content: "First scope #{id}", source_id: id, mention?: false)

      captured = captured_message!(first, emitted)
      emit_message(first, :shared, content: "First scope #{id}", source_id: id, mention?: false)
      assert captured_message!(first, emitted).id == captured.id

      other_emission =
        emit_message(second, :shared,
          content: "Second scope #{id}",
          source_id: id,
          mention?: false
        )

      refute captured_message!(second, other_emission).id == captured.id
      refute transcript!(first, emitted).id == transcript!(second, other_emission).id

      assert Repo.aggregate(
               from(p in TranscriptMessage, where: p.message_id == ^captured.id),
               :count
             ) == 1
    end

    refute_received {:channel_llm_request, _, _}
  end
end
