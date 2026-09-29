defmodule Zaq.Bench.LiveRAG.ConfigurationTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Bench.LiveRAG.Configuration
  alias Zaq.Engine.Connect.Grant
  alias Zaq.System

  @actor %{kind: :system, subject: "liverag-corpus-preparation"}

  test "loads persisted embedding settings and canonical authentication without source writes" do
    credential = ai_credential_fixture(%{api_key: "benchmark-secret"})
    System.set_config("embedding.credential_id", credential.id)
    System.set_config("embedding.model", "benchmark-model")
    System.set_config("embedding.dimension", "1536")

    grant_before = Repo.get_by!(Grant, credential_id: credential.connect_credential_id)

    assert {:ok, snapshot} = Configuration.load(%{source: Repo}, @actor)
    assert snapshot.embedding.model == "benchmark-model"
    assert snapshot.embedding.dimension == 1536
    assert snapshot.provider.id == credential.id
    assert snapshot.resolved_credential.authentication == %{api_key: "benchmark-secret"}
    assert {:ok, client_config} = Configuration.embedding_client_config(snapshot)
    assert client_config.model == "benchmark-model"
    assert client_config.endpoint == credential.endpoint
    assert client_config.api_key == "benchmark-secret"
    assert String.length(snapshot.fingerprint) == 64
    refute inspect(snapshot) =~ "benchmark-secret"
    assert Repo.get!(Grant, grant_before.id) == grant_before
  end

  test "fingerprint changes with embedding contract while authentication stays out" do
    credential = ai_credential_fixture(%{api_key: "benchmark-secret"})
    System.set_config("embedding.credential_id", credential.id)
    System.set_config("embedding.model", "first-model")
    assert {:ok, first} = Configuration.load(%{source: Repo}, @actor)

    System.set_config("embedding.model", "second-model")
    assert {:ok, second} = Configuration.load(%{source: Repo}, @actor)
    refute first.fingerprint == second.fingerprint
    refute first.fingerprint =~ "benchmark-secret"
  end

  test "missing credential and invalid actor fail without implicit permission" do
    assert {:error, :embedding_credential_missing} = Configuration.load(%{source: Repo}, @actor)

    credential = ai_credential_fixture(%{auth_kind: "none"})
    System.set_config("embedding.credential_id", credential.id)
    assert {:error, :missing_execution_actor} = Configuration.load(%{source: Repo}, nil)
    assert {:ok, no_auth_snapshot} = Configuration.load(%{source: Repo}, @actor)
    assert {:ok, %{api_key: ""}} = Configuration.embedding_client_config(no_auth_snapshot)

    System.set_config("embedding.credential_id", 999_998)
    assert {:error, :embedding_provider_missing} = Configuration.load(%{source: Repo}, @actor)
  end

  test "OAuth provider is refused before any grant refresh" do
    credential =
      ai_credential_fixture(%{
        auth_kind: "oauth2",
        metadata: %{"client_id" => "benchmark-client"}
      })

    System.set_config("embedding.credential_id", credential.id)

    assert {:error, %{reason: :unsupported_auth_kind}} =
             Configuration.load(%{source: Repo}, @actor)
  end

  test "configured zaq_router endpoint and grant key reach the embedding client snapshot" do
    credential =
      ai_credential_fixture(%{
        provider: "zaq_router",
        endpoint: "https://router.example/v1",
        api_key: "router-secret"
      })

    System.set_config("embedding.credential_id", credential.id)
    assert {:ok, snapshot} = Configuration.load(%{source: Repo}, @actor)
    assert {:ok, client_config} = Configuration.embedding_client_config(snapshot)
    assert client_config.endpoint == "https://router.example/v1"
    assert client_config.api_key == "router-secret"
  end
end
