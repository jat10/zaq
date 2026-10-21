defmodule Zaq.TestSupport.Channels.Integration.Assertions do
  @moduledoc "Canonical transcript lookup and independently expected content assertions."
  import Ecto.Query
  import ExUnit.Assertions

  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
  alias Zaq.Repo
  alias Zaq.TestSupport.Channels.Integration.Session

  @doc "Finds the actual native input through this connector's canonical placement."
  @spec captured_message!(Session.t(), map()) :: Message.t()
  def captured_message!(session, emission) do
    Repo.one!(
      from m in Message,
        join: p in TranscriptMessage,
        on: p.message_id == m.id,
        join: t in Transcript,
        on: t.id == p.transcript_id,
        where:
          t.channel_config_id == ^session.connector.id and
            t.external_channel_id == ^emission.channel_id and
            m.external_message_id == ^emission.source_id,
        distinct: m.id,
        select: m
    )
  end

  @doc "Locates this connector's exact native room/thread transcript after completion."
  @spec transcript!(Session.t(), map()) :: Transcript.t()
  def transcript!(session, emission) do
    connector = session.connector.id
    room = emission.channel_id
    thread = emission.thread_id

    query =
      from t in Transcript,
        where: t.channel_config_id == ^connector and t.external_channel_id == ^room

    query =
      if thread,
        do: from(t in query, where: t.external_thread_id == ^thread),
        else: from(t in query, where: is_nil(t.external_thread_id))

    Repo.one!(query)
  end

  @doc "Checks visible content and returns the independently authorized canonical projection."
  @spec assert_transcript(Session.t(), map(), String.t(), [String.t()]) :: list()
  def assert_transcript(session, emission, strategy, expected_contents) do
    transcript = transcript!(session, emission)
    assert transcript.strategy == strategy
    assert {:ok, messages} = Conversations.list_canonical_messages(session.person, transcript.id)
    assert Enum.map(messages, & &1.content) == expected_contents
    messages
  end
end
