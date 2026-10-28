defmodule Zaq.Accounts.ProfileIdentifiersTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.CommunicationFixtures

  alias Zaq.Accounts.{People, Person, PersonChannel, PersonIdentity}

  @lid "123456789@lid"
  @pn "15551234567@s.whatsapp.net"

  test "profile identifiers link to the same person and originating connector" do
    config = connector_fixture("whatsapp")
    attrs = %{channel_config_id: config.id, channel_id: @lid}
    assert {:ok, original} = People.find_or_create_from_channel("whatsapp", attrs)

    assert {:ok, person} =
             People.find_or_create_from_channel(
               "whatsapp",
               Map.merge(attrs, %{additional_identifiers: [@pn], phone: "+15551234567"})
             )

    assert person.id == original.id
    assert person.phone == "+15551234567"
    assert Enum.sort(Enum.map(person.channels, & &1.channel_identifier)) == Enum.sort([@lid, @pn])

    for channel <- person.channels do
      assert channel.platform == "whatsapp"
      assert channel.person_id == person.id
      assert channel.channel_config_id == config.id

      assert %PersonIdentity{
               person_id: owner,
               platform: "whatsapp",
               authority: "global",
               identifier: identifier
             } = Repo.get!(PersonIdentity, channel.person_identity_id)

      assert owner == person.id
      assert identifier == channel.channel_identifier
    end

    assert {:ok, by_alias} = People.match_by_channel("whatsapp", @pn, config.id)
    assert by_alias.id == person.id
  end

  test "additional identifiers do not inherit the primary identifier's DM route" do
    config = connector_fixture("whatsapp")

    assert {:ok, person} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @lid,
               dm_channel_id: @lid,
               additional_identifiers: [@pn]
             })

    assert Enum.find(person.channels, &(&1.channel_identifier == @lid)).dm_channel_id == @lid
    assert is_nil(Enum.find(person.channels, &(&1.channel_identifier == @pn)).dm_channel_id)
  end

  test "an alias already owned by the same Person can gain another connector link" do
    first = connector_fixture("whatsapp")
    second = Zaq.WhatsAppFixtures.connector()

    assert {:ok, person} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: first.id,
               channel_id: @lid,
               additional_identifiers: [@pn]
             })

    original_identities = MapSet.new(Enum.map(person.channels, & &1.person_identity_id))

    assert {:ok, enriched} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: second.id,
               channel_id: @lid,
               additional_identifiers: [@pn]
             })

    assert enriched.id == person.id
    assert length(enriched.channels) == 4
    assert MapSet.new(Enum.map(enriched.channels, & &1.person_identity_id)) == original_identities

    assert enriched.channels
           |> Enum.filter(&(&1.channel_config_id == second.id))
           |> Enum.map(& &1.channel_identifier)
           |> Enum.sort() == Enum.sort([@lid, @pn])
  end

  test "phone enrichment without explicit identifiers does not manufacture aliases" do
    config = connector_fixture("whatsapp")

    for aliases <- [nil, []] do
      assert {:ok, person} =
               People.find_or_create_from_channel("whatsapp", %{
                 channel_config_id: config.id,
                 channel_id: @lid,
                 phone: "+15551234567",
                 additional_identifiers: aliases
               })

      assert [%{channel_identifier: @lid}] = person.channels
    end
  end

  test "an alias owned elsewhere rolls back other aliases and profile updates" do
    config = connector_fixture("whatsapp")
    other_config = Zaq.WhatsAppFixtures.connector()

    assert {:ok, owner} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: other_config.id,
               channel_id: @pn
             })

    attrs = %{channel_config_id: config.id, channel_id: @lid}
    assert {:ok, person} = People.find_or_create_from_channel("whatsapp", attrs)
    channels = People.list_person_channels(person.id)
    identities = Repo.aggregate(PersonIdentity, :count)

    assert {:error, conflict} =
             People.find_or_create_from_channel(
               "whatsapp",
               Map.merge(attrs, %{
                 additional_identifiers: ["another-verified-id", @pn],
                 display_name: "New name",
                 phone: "+15551234567"
               })
             )

    assert errors_on(conflict).channel_identifier != []
    assert People.get_person!(person.id).phone == person.phone
    assert People.get_person!(person.id).full_name == person.full_name
    assert People.list_person_channels(person.id) == channels
    assert Repo.aggregate(PersonIdentity, :count) == identities
    assert {:ok, unchanged} = People.match_by_channel("whatsapp", @pn, other_config.id)
    assert unchanged.id == owner.id
  end

  test "conflicting enrichment rolls back a newly discovered primary person too" do
    config = connector_fixture("whatsapp")

    assert {:ok, _} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @pn
             })

    counts = counts()

    assert {:error, _} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @lid,
               additional_identifiers: [@pn]
             })

    assert counts() == counts
  end

  test "malformed additional identifiers fail without persisting partial discoveries" do
    config = connector_fixture("whatsapp")
    counts = counts()

    for invalid <- [@pn, %{}, [nil], [123], [""], [" \t"], [@pn, %{}]] do
      assert {:error, :invalid_additional_identifiers} =
               People.find_or_create_from_channel("whatsapp", %{
                 channel_config_id: config.id,
                 channel_id: @lid,
                 additional_identifiers: invalid
               })

      assert counts() == counts
    end
  end

  property "duplicate identifiers and repeated enrichment are idempotent" do
    config = connector_fixture("whatsapp")

    check all(
            aliases <- list_of(member_of([@lid, @pn]), min_length: 1, max_length: 12),
            max_runs: 15
          ) do
      attrs = %{
        channel_config_id: config.id,
        channel_id: @lid,
        additional_identifiers: [@pn | aliases]
      }

      assert {:ok, person} = People.find_or_create_from_channel("whatsapp", attrs)
      assert {:ok, repeated} = People.find_or_create_from_channel("whatsapp", attrs)
      assert repeated.id == person.id
      assert repeated.channels == person.channels
      assert length(repeated.channels) == 2
    end
  end

  defp counts do
    {Repo.aggregate(Person, :count), Repo.aggregate(PersonChannel, :count),
     Repo.aggregate(PersonIdentity, :count)}
  end
end
