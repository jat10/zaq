defmodule Zaq.Engine.LinkedDeviceConfirmation do
  @moduledoc """
  Atomically creates a confirmed WhatsApp connector and its encrypted pairing state.

  Accepts only the Channels-owned frozen snapshot via the trusted runtime Action.
  The attempt UUID serializes repeated confirmations, including a lost response;
  persistence never starts a connection while the transaction is open. Channels
  excludes volatile messaging sessions and seeds them locally after this commits.
  """
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Repo

  def save(%{attempt_id: attempt, identity: %{phone_number: phone} = identity, records: records})
      when is_binary(attempt) and is_binary(phone) and is_map(records) and map_size(records) > 0 do
    with {:ok, _} <- Ecto.UUID.cast(attempt),
         true <- Regex.match?(~r/^\+[0-9]{5,15}$/, phone) do
      Repo.transaction(fn ->
        # Serialize duplicate requests before checking the durable receipt.
        SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "linked-device:" <> attempt
        ])

        existing =
          Repo.one(
            from c in ChannelConfig,
              where: fragment("?->>'pairing_attempt' = ?", c.settings, ^attempt)
          )

        existing || create(attempt, identity, records)
      end)
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def save(_), do: {:error, :invalid_snapshot}

  defp create(attempt, identity, records) do
    name = identity[:display_name] || identity.phone_number

    settings = %{
      "pairing_attempt" => attempt,
      "account_identity" => Map.take(identity, [:phone_number, :display_name, :account_jids])
    }

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: name,
        provider: "whatsapp",
        kind: "retrieval",
        enabled: true,
        settings: settings
      })
      |> Repo.insert!()

    binding =
      case Connect.credential_document(%{op: :bind, channel_config_id: config.id}) do
        {:ok, binding} -> binding
        {:error, reason} -> Repo.rollback(reason)
      end

    Enum.each(records, fn {{namespace, key}, value} ->
      request = %{
        op: :put,
        binding: binding,
        namespace: namespace,
        key: encode(key),
        value: encode(value)
      }

      case Connect.credential_document(request) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    Repo.get!(ChannelConfig, config.id)
  end

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()
end
