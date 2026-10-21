defmodule Zaq.Channels.Integration.TranscriptTest do
  use Zaq.TestSupport.Channels.Integration.Case

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.TestSupport.Channels.Integration.Registry

  for {provider, driver} <- Registry.all() do
    @provider provider

    if driver.capabilities().threads == true do
      @tag provider: provider, scenario: :thread_history
      test "#{provider}: native thread retains its parent and authorized local history" do
        session = channel_session(@provider, llm_answer: "Thread answer")
        root = emit_message(session, :shared, content: "Parent evidence", mention?: false)
        parent = transcript!(session, root)

        child =
          emit_message(session, :shared, content: "Thread question", thread_id: root.source_id)

        result = await_exchange(session, child)
        assert result.reply.thread_id == child.thread_id
        assert {:ok, %{confirmation: :confirmed}} = result.event.response
        transcript = transcript!(session, child)
        assert transcript.parent_id == parent.id
        assert transcript.external_thread_id == child.thread_id
        scope = session.scope
        assert_receive {:channel_llm_request, ^scope, request}
        input = Jason.encode!(request["input"])
        assert input =~ "Parent evidence"
        assert input =~ "Thread question"

        assert {:ok, messages} =
                 Conversations.list_canonical_messages(session.person, transcript.id)

        placements =
          Repo.all(
            from p in Conversations.TranscriptMessage,
              join: m in Message,
              on: m.id == p.message_id,
              join: t in Conversations.Transcript,
              on: t.id == p.transcript_id,
              where: t.channel_config_id == ^session.connector.id,
              select: {t.external_thread_id, p.position, m.role, m.content}
          )

        assert List.last(messages).content == "Thread answer",
               inspect(%{receipt: result.event.response, placements: placements})
      end
    end

    for room <- [:direct, :shared] do
      @room room
      @tag provider: provider, scenario: :transcript
      test "#{provider}: #{@room} canonical history preserves source, attribution and permission boundaries" do
        session = channel_session(@provider, llm_answer: "Visible answer")
        emission = emit_message(session, @room, content: "Visible input")
        result = await_exchange(session, emission)
        transcript = transcript!(session, emission)
        assert transcript.strategy == if(@room == :direct, do: "direct", else: "shared")
        assert transcript.channel_config_id == session.connector.id
        assert transcript.external_channel_id == emission.channel_id

        assert {:ok, [input, answer]} =
                 Conversations.list_canonical_messages(session.person, transcript.id)

        assert String.ends_with?(input.content, "Visible input")
        native_input = Repo.get!(Message, input.message_id)
        assert native_input.external_message_id == emission.source_id
        assert native_input.history_context["author_person_id"] == session.person.id
        assert input.role == "user"
        assert answer.content == "Visible answer"
        assert answer.role == "assistant"
        assert input.message_id != answer.message_id

        assert {:ok, [^input, ^answer]} =
                 Conversations.list_canonical_messages(session.person, transcript.id)

        execution = Repo.get_by!(ExecutionRecord, user_message_id: input.message_id)
        assert execution.status == "completed"
        assert execution.public_answer_message_id == answer.message_id
        assert {:ok, %{message_id: delivered_id}} = result.event.response
        assert Repo.get!(Message, answer.message_id).external_message_id == delivered_id
        {:ok, stranger} = People.create_person(%{full_name: "Unrelated Person"})
        assert {:error, _} = Conversations.list_canonical_messages(stranger, transcript.id)
        assert {:error, _} = Conversations.list_canonical_messages(nil, transcript.id)
      end
    end

    @tag provider: provider, scenario: :manual_permission
    test "#{provider}: explicit manual history access can be granted and revoked" do
      session = channel_session(@provider)
      emission = emit_message(session, :shared, content: "Shared record")
      await_exchange(session, emission)
      transcript = transcript!(session, emission)
      {:ok, reader} = People.create_person(%{full_name: "Manual reader"})

      resource =
        ChannelHistoryResource.for(
          Atom.to_string(@provider),
          session.connector.id,
          emission.channel_id
        )

      assert {:error, _} = Conversations.list_canonical_messages(reader, transcript.id)

      assert {:ok, permission} =
               Permissions.grant(resource, %{person_id: reader.id, access_rights: ["read"]})

      assert {:ok, [_input, _answer]} =
               Conversations.list_canonical_messages(reader, transcript.id)

      assert :ok = Permissions.revoke(resource, permission)
      assert {:error, _} = Conversations.list_canonical_messages(reader, transcript.id)

      assert {:ok, [_input, _answer]} =
               Conversations.list_canonical_messages(session.person, transcript.id)
    end

    @tag provider: provider, scenario: :connector_isolation
    test "#{provider}: identical external ids on distinct connectors remain independent" do
      first = channel_session(@provider, llm_answer: "FORBIDDEN first answer")
      emission = emit_message(first, :direct, content: "FORBIDDEN first input", source_id: "77")
      await_exchange(first, emission)
      second = channel_session(@provider, llm_answer: "Second answer")
      other = emit_message(second, :direct, content: "Second input", source_id: "77")
      await_exchange(second, other)
      scope = second.scope
      assert_receive {:channel_llm_request, ^scope, request}
      refute Jason.encode!(request["input"]) =~ "FORBIDDEN"
      assert transcript!(first, emission).id != transcript!(second, other).id
      assert_transcript(second, other, "direct", ["Second input", "Second answer"])

      assert {:error, _} =
               Conversations.list_canonical_messages(first.person, transcript!(second, other).id)

      assert length(
               Repo.all(
                 from m in Message,
                   where:
                     m.external_message_id == "77" and
                       m.source_provider == ^Atom.to_string(@provider)
               )
             ) == 2
    end
  end
end
