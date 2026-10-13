defmodule Zaq.Engine.LinkedDeviceConfirmationTest do
  use Zaq.DataCase, async: true
  alias Zaq.Engine.{ChannelConfig, LinkedDeviceConfirmation}

  test "durable attempt receipt prevents duplicates after response loss" do
    request = request()
    assert {:ok, first} = LinkedDeviceConfirmation.save(request)
    assert {:ok, second} = LinkedDeviceConfirmation.save(request)
    assert first.id == second.id
    assert first.name == "+15550001"
    assert first.settings["credential_document_id"]
  end

  test "oversized pairing credentials roll back the connector and its credential" do
    request = %{request() | records: %{{"creds", :self} => String.duplicate("s", 1024 * 1024)}}
    count = Repo.aggregate(ChannelConfig, :count)
    assert {:error, _} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(ChannelConfig, :count) == count
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
      records: %{{"creds", :self} => %{paired: true}}
    }
  end
end
