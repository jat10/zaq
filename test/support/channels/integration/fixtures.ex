defmodule Zaq.TestSupport.Channels.Integration.Fixtures do
  @moduledoc "Channel-enabled agent and connector-scoped Person/routing fixtures."

  import ExUnit.Assertions
  import Zaq.SystemConfigFixtures, only: [ai_credential_fixture: 1]

  alias Zaq.Accounts.People
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Repo

  @doc "Creates only the saved input fixtures; messages and transcripts must come from ingress."
  @spec create!(map(), String.t(), String.t(), keyword()) :: map()
  def create!(handle, endpoint, scope, opts \\ []) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    assert {:ok, agent} =
             Zaq.Agent.create_agent(%{
               name: "Channel agent #{scope}",
               job: "Answer briefly.",
               model: "gpt-4.1-mini",
               model_max_context_tokens: 128_000,
               credential_id: credential.id,
               strategy: "react",
               enabled_tool_keys: Keyword.get(opts, :tool_keys, []),
               active: true,
               conversation_enabled: true,
               advanced_options: %{"stream" => false}
             })

    connector =
      %ChannelConfig{}
      |> ChannelConfig.changeset(
        Map.merge(
          %{
            name: "Channel #{scope}",
            provider: to_string(handle.provider),
            kind: "retrieval",
            enabled: true
          },
          Map.merge(handle.connector_attrs, Keyword.get(opts, :connector_attrs, %{}))
        )
      )
      |> Repo.insert!()

    assert {:ok, person} = People.create_person(%{full_name: "Channel sender #{scope}"})

    assert {:ok, _} =
             People.add_channel(%{
               person_id: person.id,
               platform: to_string(handle.provider),
               channel_identifier: handle.sender.id,
               dm_channel_id: handle.rooms.direct,
               channel_config_id: connector.id
             })

    assert {:ok, _} =
             IncomingMessageRouting.upsert_rule(
               %{channel_config_id: connector.id},
               %{routing_mode: :agent, configured_agent_id: agent.id}
             )

    %{agent: agent, connector: connector, person: person, credential: credential}
  end
end
