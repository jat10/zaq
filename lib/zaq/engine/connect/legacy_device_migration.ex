defmodule Zaq.Engine.Connect.LegacyDeviceMigration do
  @moduledoc """
  Offline forward data migration from legacy linked-device rows to canonical grants.

  Run only with channel runtimes stopped. Canonical changesets and encrypted types
  validate writes; no Oban/NodeRouter runtime is required during Ecto migration.
  The outer migration drops source tables only after every conversion succeeds.
  No source values or changesets are returned in errors. Existing IDs, profiles,
  disabled/archive state and independently migrated grant material are preserved.
  """
  import Ecto.Query
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo
  alias Zaq.System.SecretConfig

  @doc "Migrates all source bindings atomically, including inactive connectors."
  @spec run() :: {:ok, non_neg_integer()} | {:error, atom()}
  def run do
    Repo.transaction(fn ->
      bindings =
        Repo.all(
          from l in "connect_linked_devices",
            order_by: l.id,
            select: %{
              id: l.id,
              channel_config_id: l.channel_config_id,
              credential_id: l.credential_id,
              profile: l.profile
            }
        )

      Enum.each(bindings, &migrate/1)

      ensure(
        not Repo.exists?(from c in Credential, where: c.auth_kind == "linked_device"),
        :legacy_binding_conflict
      )

      length(bindings)
    end)
  end

  defp migrate(binding) do
    config =
      Repo.one(
        from c in ChannelConfig, where: c.id == ^binding.channel_config_id, lock: "FOR UPDATE"
      )

    credential =
      Repo.one(from c in Credential, where: c.id == ^binding.credential_id, lock: "FOR UPDATE")

    ensure(
      match?(%ChannelConfig{}, config) and match?(%Credential{}, credential),
      :legacy_binding_conflict
    )

    ensure(
      config.provider == credential.provider and
        binding.profile == "zaq_linked_device_#{config.id}",
      :legacy_binding_conflict
    )

    target = config.settings["credential_document_id"]
    ensure(is_nil(target) or target == credential.id, :legacy_binding_conflict)

    case credential.auth_kind do
      "linked_device" ->
        convert(config, credential, binding)

      "api_key" ->
        validate_migrated(config, credential, target)

      _ ->
        Repo.rollback(:legacy_binding_conflict)
    end
  end

  defp validate_migrated(config, credential, target) do
    ensure(
      target == credential.id and credential.secret_binding == :grant and
        credential.personal_credential_policy == :disabled and
        credential.metadata["subject"] == "channel_config:#{config.id}" and
        credential.metadata["auth_profile_id"] == "credential_document_v1",
      :legacy_binding_conflict
    )

    ensure(
      Repo.exists?(
        from g in Grant,
          where:
            g.credential_id == ^credential.id and g.resource_type == "connect_credential" and
              g.resource_id == ^to_string(credential.id) and g.owner_type == "org" and
              is_nil(g.owner_id)
      ),
      :legacy_binding_conflict
    )
  end

  defp convert(config, credential, binding) do
    ensure(
      not Repo.exists?(from g in Grant, where: g.credential_id == ^credential.id),
      :legacy_binding_conflict
    )

    records =
      Repo.all(
        from s in "connect_linked_device_states",
          where: s.linked_device_id == ^binding.id,
          select: %{namespace: s.namespace, key: s.key, encrypted_value: s.encrypted_value}
      )
      |> Enum.reduce(%{}, &record/2)

    document = Jason.encode!(%{version: 1, records: records})
    ensure(byte_size(document) <= 16 * 1024 * 1024, :legacy_state_too_large)

    updated =
      credential
      |> Credential.changeset(%{
        auth_kind: "api_key",
        secret_binding: :grant,
        personal_credential_policy: :disabled,
        metadata: %{
          "auth_profile_id" => "credential_document_v1",
          "subject" => "channel_config:#{config.id}"
        }
      })
      |> persist(:legacy_binding_conflict)

    %Grant{}
    |> Grant.credential_changeset(updated, %{
      owner_type: "org",
      owner_id: nil,
      api_key: document,
      status: "active"
    })
    |> persist(:legacy_state_unreadable)

    config
    |> Ecto.Changeset.change(
      settings: Map.put(config.settings, "credential_document_id", credential.id)
    )
    |> persist(:legacy_binding_conflict)
  end

  defp record(record, acc) do
    ensure(address?(record.namespace) and address?(record.key), :legacy_state_unreadable)
    ensure(SecretConfig.encrypted?(record.encrypted_value), :legacy_state_unreadable)

    value =
      case SecretConfig.decrypt(record.encrypted_value) do
        {:ok, value} -> value
        _ -> Repo.rollback(:legacy_state_unreadable)
      end

    ensure(valid_term?(value) and valid_term?(record.key), :legacy_state_unreadable)
    ensure(byte_size(value) <= 1024 * 1024, :legacy_state_too_large)
    namespace = Map.get(acc, record.namespace, %{})
    ensure(not Map.has_key?(namespace, record.key), :legacy_binding_conflict)
    Map.put(acc, record.namespace, Map.put(namespace, record.key, Base.encode64(value)))
  end

  defp address?(value) when is_binary(value),
    do: byte_size(value) in 1..512 and String.valid?(value)

  defp address?(_), do: false

  defp valid_term?(value) do
    case Base.decode64(value) do
      # Keep authenticated source bytes opaque. Protocol modules may not yet be
      # loaded during offline migration, so safe decoding can reject valid atoms.
      # The callback performs full safe decoding when the adapter reads.
      {:ok, <<131, tag, _::binary>>} when tag != 80 ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp persist(changeset, error) do
    case Repo.insert_or_update(changeset) do
      {:ok, record} -> record
      {:error, _} -> Repo.rollback(error)
    end
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: Repo.rollback(reason)
end
