defmodule Zaq.Engine.Connect.LinkedDeviceStorage do
  @moduledoc """
  Engine-owned encrypted linked-device protocol persistence.

  This is a privileged runtime API, not a Person or BO management API. Cross-role
  callers must use the confidential synchronous linked_device_storage event with
  explicit linked_device_runtime authorization. Nil actors alone grant no access.
  Every operation revalidates the stored connector/credential association.
  """

  import Ecto.Query

  alias Zaq.Channels.LinkedDevice.Config
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect.{Credential, LinkedDevice, LinkedDeviceState}
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString

  @timeout 750

  @doc "Creates or reloads a connector's credential association under a row lock."
  @spec bind(pos_integer()) :: {:ok, map()} | {:error, term()}
  def bind(id) when is_integer(id) and id > 0 do
    Repo.transaction(
      fn ->
        config = Repo.one(from(c in ChannelConfig, where: c.id == ^id, lock: "FOR UPDATE"))

        with :ok <- available(config),
             {:ok, profile} <- Config.profile(config) do
          load_or_create(config, profile)
          |> Map.take([:id, :channel_config_id, :credential_id, :profile])
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @timeout
    )
  end

  def bind(_id), do: {:error, :invalid_request}

  defp load_or_create(config, profile) do
    Repo.get_by(LinkedDevice, channel_config_id: config.id) || create_binding(config, profile)
  end

  @doc "Executes a validated protocol storage operation for an exact binding."
  @spec dispatch(map()) :: term()
  def dispatch(%{op: :bind, channel_config_id: id}), do: bind(id)

  def dispatch(%{binding: binding, op: op} = request) when is_map(binding) do
    with {:ok, stored} <- resolve_binding(binding),
         :ok <- validate_address(request) do
      execute(op, stored, request)
    end
  end

  def dispatch(_request), do: {:error, :invalid_request}

  defp create_binding(config, profile) do
    credential =
      %Credential{}
      |> Credential.changeset(%{
        name: "Linked device #{config.id}",
        provider: config.provider,
        auth_kind: "linked_device"
      })
      |> Repo.insert!()

    %LinkedDevice{}
    |> LinkedDevice.changeset(%{
      channel_config_id: config.id,
      credential_id: credential.id,
      profile: profile
    })
    |> Repo.insert!()
  end

  defp resolve_binding(%{
         id: id,
         channel_config_id: config_id,
         credential_id: credential_id,
         profile: profile
       }) do
    binding = Repo.get(LinkedDevice, id, timeout: @timeout)
    config = Repo.get(ChannelConfig, config_id, timeout: @timeout)
    credential = Repo.get(Credential, credential_id, timeout: @timeout)

    with %LinkedDevice{
           channel_config_id: ^config_id,
           credential_id: ^credential_id,
           profile: ^profile
         } <- binding,
         %Credential{auth_kind: "linked_device", provider: provider} <- credential,
         %{provider: ^provider} <- config,
         :ok <- available(config) do
      {:ok, binding}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_binding}
    end
  end

  defp resolve_binding(_binding), do: {:error, :invalid_binding}

  defp available(%ChannelConfig{kind: "retrieval", enabled: true, archived_at: nil}), do: :ok
  defp available(_config), do: {:error, :connector_unavailable}

  defp validate_address(%{op: op}) when op in [:clear, :list_profiles], do: :ok
  defp validate_address(%{op: :list_keys, namespace: ns}) when is_binary(ns), do: :ok
  defp validate_address(%{namespace: ns, key: key}) when is_binary(ns) and is_binary(key), do: :ok
  defp validate_address(_request), do: {:error, :invalid_request}

  defp execute(:get, binding, request) do
    case Repo.one(record_query(binding, request), timeout: @timeout) do
      nil -> :error
      record -> decrypt(record.encrypted_value)
    end
  end

  defp execute(:put, binding, %{value: value} = request) when is_binary(value) do
    with {:ok, encrypted} <- EncryptedString.encrypt(value) do
      %LinkedDeviceState{}
      |> LinkedDeviceState.changeset(%{
        linked_device_id: binding.id,
        namespace: request.namespace,
        key: request.key,
        encrypted_value: encrypted
      })
      |> Repo.insert(
        conflict_target: [:linked_device_id, :namespace, :key],
        on_conflict: {:replace, [:encrypted_value, :updated_at]},
        timeout: @timeout
      )
      |> case do
        {:ok, _record} -> :ok
        {:error, _changeset} -> {:error, :storage_write_failed}
      end
    end
  end

  defp execute(:delete, binding, request) do
    Repo.delete_all(record_query(binding, request), timeout: @timeout)
    :ok
  end

  defp execute(:clear, binding, _request) do
    Repo.delete_all(from(s in LinkedDeviceState, where: s.linked_device_id == ^binding.id),
      timeout: @timeout
    )

    :ok
  end

  defp execute(:list_profiles, binding, _request), do: {:ok, [binding.profile]}

  defp execute(:list_keys, binding, %{namespace: namespace}) do
    {:ok,
     Repo.all(
       from(s in LinkedDeviceState,
         where: s.linked_device_id == ^binding.id and s.namespace == ^namespace,
         select: s.key
       ),
       timeout: @timeout
     )}
  end

  defp execute(_op, _binding, _request), do: {:error, :invalid_request}

  defp record_query(binding, request) do
    from(s in LinkedDeviceState,
      where:
        s.linked_device_id == ^binding.id and s.namespace == ^request.namespace and
          s.key == ^request.key
    )
  end

  defp decrypt(value) do
    if EncryptedString.encrypted?(value),
      do: EncryptedString.decrypt(value),
      else: {:error, :invalid_ciphertext}
  end
end
