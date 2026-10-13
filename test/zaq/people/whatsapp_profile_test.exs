defmodule Zaq.People.WhatsAppProfileTest do
  use Zaq.DataCase, async: false

  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Accounts.People
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.People.IdentityResolver

  test "phone JIDs populate the directory and preserve edited name and phone" do
    {config, _conn} = connection()
    incoming = incoming(config, "15551234567:4@s.whatsapp.net", "Sender Name")
    assert {:ok, person} = IdentityResolver.resolve(incoming, [])
    assert person.full_name == "Sender Name"
    assert person.phone == "+15551234567"

    assert {:ok, _} =
             People.update_person(person, %{
               full_name: "Directory @ Name",
               phone: "+15550000000",
               email: "directory@example.com"
             })

    assert {:ok, same} = IdentityResolver.resolve(incoming, [])
    assert same.id == person.id
    assert same.full_name == "Directory @ Name"
    assert same.phone == "+15550000000"
  end

  test "absent and placeholder push names do not prevent Person creation" do
    {config, _} = connection()

    for {name, index} <- Enum.with_index([nil, "", " ", "~", " ~ "]) do
      jid = "1555123456#{index}@s.whatsapp.net"
      assert {:ok, person} = IdentityResolver.resolve(incoming(config, jid, name), [])
      assert person.full_name == jid
      assert person.phone == "+1555123456#{index}"
    end
  end

  test "LID phone enrichment is connection scoped and can arrive after the first message" do
    {first, conn} = connection()
    {second, _} = connection()
    lid = "1234567890@lid"
    assert {:ok, person} = IdentityResolver.resolve(incoming(first, lid, nil), [])
    assert is_nil(person.phone)

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(conn), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, updated} = IdentityResolver.resolve(incoming(first, lid, "Sender Name"), [])
    assert updated.id == person.id
    assert updated.full_name == "Sender Name"
    assert updated.phone == "+15551234567"

    assert {:ok, isolated} = IdentityResolver.resolve(incoming(second, lid, "Other Account"), [])
    refute isolated.id == person.id
    assert is_nil(isolated.phone)
  end

  test "phone enrichment does not conflict across connectors or merge by display name" do
    people =
      for _ <- 1..2 do
        {config, _} = connection()
        incoming = incoming(config, "15551234567@s.whatsapp.net", "Same Name")
        assert {:ok, person} = IdentityResolver.resolve(incoming, [])
        assert {:ok, repeated} = IdentityResolver.resolve(incoming, [])
        assert repeated.id == person.id
        assert repeated.phone == "+15551234567"
        person
      end

    assert [first, second] = people
    refute first.id == second.id
  end

  test "legacy JID phone values are repaired when the phone becomes available" do
    {config, _} = connection()
    jid = "15551234567@s.whatsapp.net"

    assert {:ok, person} =
             People.find_or_create_from_channel("whatsapp", %{
               "channel_id" => jid,
               "channel_config_id" => config.id,
               "phone" => jid
             })

    assert {:ok, person} = People.update_person(person, %{email: "legacy@example.com"})
    refute person.incomplete
    assert {:ok, updated} = IdentityResolver.resolve(incoming(config, jid, "Sender Name"), [])
    assert updated.id == person.id
    assert updated.phone == "+15551234567"
    assert updated.full_name == "Sender Name"
  end

  defp connection do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: Ecto.UUID.generate(),
        provider: "whatsapp",
        kind: "retrieval"
      })
      |> Repo.insert!()

    assert {:ok, conn} = Amarula.Testing.start_offline(profile: "zaq_linked_device_#{config.id}")
    on_exit(fn -> Amarula.stop(conn) end)
    {config, conn}
  end

  defp incoming(config, sender, name) do
    assert {:ok, chat} =
             Adapter.transform_incoming(%{
               id: Ecto.UUID.generate(),
               channel_jid: "120363000000000@g.us",
               from_jid: sender,
               pushname: name,
               text: "hello"
             })

    JidoChatBridge.to_internal(chat, config)
  end
end
