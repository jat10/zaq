defmodule Zaq.Engine.LinkedDeviceConfirmationTest do
  use Zaq.DataCase, async: true
  import Ecto.Query
  alias Zaq.Engine.{ChannelConfig, Connect, LinkedDeviceConfirmation}

  test "durable attempt receipt prevents duplicates after response loss" do
    request = request()
    assert {:ok, first} = LinkedDeviceConfirmation.save(request)
    assert {:ok, second} = LinkedDeviceConfirmation.save(request)
    assert first.id == second.id
    assert first.name == "+15550001"
    assert first.settings["credential_document_id"]
  end

  test "oversized pairing credentials roll back the connector and its credential" do
    request = %{
      request()
      | records: %{{"creds", "self"} => String.duplicate("s", 1024 * 1024 + 1)}
    }

    count = Repo.aggregate(ChannelConfig, :count)
    assert {:error, _} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "confirmation persists every record with one batch mutation after provisioning" do
    records = Map.new(1..20, &{{"creds", to_string(&1)}, "opaque-#{&1}"})
    request = %{request() | records: records}
    assert {:ok, config} = LinkedDeviceConfirmation.save(request)
    credential_id = config.settings["credential_document_id"]
    binding = %{channel_config_id: config.id, credential_id: credential_id}

    for {{namespace, key}, value} <- records do
      assert {:ok, ^value} =
               Connect.credential_document(%{
                 op: :get,
                 binding: binding,
                 namespace: namespace,
                 key: key
               })
    end

    notifications =
      from j in Oban.Job,
        where: j.args["credential_id"] == ^credential_id and j.args["kind"] == "grant_replaced"

    # One notification provisions the empty grant, one persists the complete batch.
    assert Repo.aggregate(notifications, :count) == 2
    assert {:ok, ^config} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(notifications, :count) == 2
  end

  test "absent or LID-only phone identity cannot be confirmed" do
    for phone <- [nil, "123456@lid", "not a number", "+", ""] do
      assert {:error, _} =
               LinkedDeviceConfirmation.save(%{request() | identity: %{phone_number: phone}})
    end
  end

  defp request do
    %{
      attempt_id: Ecto.UUID.generate(),
      identity: %{phone_number: "+15550001", display_name: nil},
      records: %{{"creds", "self"} => "opaque-package-record"}
    }
  end
end
