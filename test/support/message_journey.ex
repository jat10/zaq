defmodule Zaq.TestSupport.MessageJourney do
  @moduledoc "Real provider ingress, connector routing and persistence barriers for message journeys."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Zaq.Accounts.People
  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.TestSupport.{ChannelFileFixtures, MattermostHistoryFixture}

  def mattermost!(namespace, endpoint, settings \\ %{}) do
    config =
      ChannelFileFixtures.config!("mattermost", namespace, %{
        url: String.trim_trailing(endpoint, "/v1"),
        token: "test-token",
        settings:
          Map.put_new(settings, "jido_chat", %{"bot_name" => "zaq", "bot_user_id" => "bot"})
      })

    on_exit(fn ->
      Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    config
  end

  def email!(namespace, smtp, username, attrs \\ %{}) do
    ChannelFileFixtures.config!(
      "email:imap",
      namespace,
      Map.merge(
        %{
          url: "imap://127.0.0.1",
          token: "synthetic-unused",
          settings: %{
            "imap" => %{
              "username" => username,
              "smtp_config_id" => smtp.id,
              "selected_mailboxes" => ["INBOX"]
            }
          }
        },
        attrs
      )
    )
  end

  def route!(config, agent) do
    assert {:ok, _} =
             IncomingMessageRouting.upsert_rule(
               %{channel_config_id: config.id},
               %{routing_mode: :agent, configured_agent_id: agent.id}
             )
  end

  def bind!(provider, config, person, identifier, attrs \\ %{}) do
    assert {:ok, _} =
             People.add_channel(
               Map.merge(
                 %{
                   person_id: person.id,
                   platform: to_string(provider),
                   channel_identifier: identifier,
                   channel_config_id: config.id
                 },
                 attrs
               )
             )
  end

  def ingest(%{provider: "email:imap"} = config, payload, opts) do
    assert :ok = EmailBridge.from_listener(config, payload, opts)
  end

  def ingest(%{provider: "mattermost"} = config, payload, opts) do
    result =
      if opts[:conversation_type] == :one_to_one do
        MattermostHistoryFixture.direct_post(config, payload)
      else
        MattermostHistoryFixture.post(
          config,
          opts[:root_author],
          Keyword.get(opts, :mentioned, true),
          payload
        )
      end

    assert {{:ok, _}, _} = result
  end

  def await_writer(writer, timeout \\ 10_000) do
    ref = Process.monitor(writer)
    assert_receive {:DOWN, ^ref, :process, ^writer, reason}, timeout
    assert reason in [:normal, :noproc]
  end

  def observe_delivery(owner) do
    handler = {__MODULE__, owner}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:zaq, :repo, :query], [:zaq, :node_router, :async, :failed]],
        &__MODULE__.observe_event/4,
        {handler, owner}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def observe_event([:zaq, :repo, :query], _, metadata, {handler, owner}),
    do: observe_query(metadata, handler, owner)

  def observe_event([:zaq, :node_router, :async, :failed], _, metadata, {_, owner}),
    do: send(owner, {:delivery_failed, metadata.trace_id, self()})

  def observe_query(%{source: "messages"} = metadata, _handler, owner) do
    if String.starts_with?(metadata.query, ["INSERT", "UPDATE"]) do
      for %{"delivery_confirmation" => %{"channel_config_id" => id}} <-
            metadata[:cast_params] || [],
          do: send(owner, {:delivery_writer, id, self()})
    end
  end

  def observe_query(%{query: "commit"}, handler, owner) do
    if Process.delete(handler), do: send(owner, {:journey_delivery_committed, self()})
    if Process.delete({handler, :queued}), do: send(owner, :journey_input_queued)
    if Process.delete({handler, :denied}), do: send(owner, {:journey_input_denied, self()})
  end

  def observe_query(%{source: "transcript_messages"} = metadata, handler, _owner) do
    if String.starts_with?(metadata.query, "INSERT") and
         "provider_confirmed" in (metadata[:cast_params] || []),
       do: Process.put(handler, true)
  end

  def observe_query(%{source: "execution_records"} = metadata, handler, _owner) do
    if String.starts_with?(metadata.query, "UPDATE") and
         "queued" in (metadata[:cast_params] || []),
       do: Process.put({handler, :queued}, true)

    if String.starts_with?(metadata.query, "UPDATE") and
         "failed" in (metadata[:cast_params] || []),
       do: Process.put({handler, :denied}, true)
  end

  def observe_query(_metadata, _handler, _owner), do: :ok
end
