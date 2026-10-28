defmodule Zaq.People.ProfileIdentifiersTest do
  use Zaq.DataCase, async: false

  import Mox
  import Zaq.CommunicationFixtures

  alias Jido.Chat.UserInfo
  alias Zaq.Accounts.People
  alias Zaq.Channels.{JidoChatBridge, ProfileAdapterMock}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver
  alias Zaq.TestSupport.ApplicationEnv

  @lid "123456789@lid"
  @pn "15551234567@s.whatsapp.net"
  @phone "+15551234567"

  setup :verify_on_exit!

  setup do
    config = connector_fixture("whatsapp")

    ApplicationEnv.put(:zaq, :channels, %{
      whatsapp: %{bridge: JidoChatBridge, adapter: ProfileAdapterMock}
    })

    stub(ProfileAdapterMock, :connection_options, fn _, _ -> %{} end)
    %{config: config}
  end

  test "typed profile metadata preserves additional identifiers after get_user", %{config: config} do
    expect_profile(%{phone: @phone, additional_identifiers: [@pn]})

    assert {:ok, profile} = JidoChatBridge.fetch_profile(@lid, details(config))
    assert profile == %{"phone" => @phone, "additional_identifiers" => [@pn]}
    refute Map.has_key?(profile, "channel_id")
  end

  test "map profiles support string-keyed metadata without changing ordinary fields", %{
    config: config
  } do
    expect(ProfileAdapterMock, :get_user, fn @lid, _ ->
      {:ok,
       %{
         "full_name" => "Profile name",
         "metadata" => %{"phone" => @phone, "additional_identifiers" => [@pn]}
       }}
    end)

    assert {:ok, profile} = JidoChatBridge.fetch_profile(@lid, details(config))
    assert profile["display_name"] == "Profile name"
    assert profile["phone"] == @phone
    assert profile["additional_identifiers"] == [@pn]
  end

  test "absent additional identifiers preserve the existing typed profile contract", %{
    config: config
  } do
    expect_profile(%{phone: @phone})

    assert {:ok, %{"phone" => @phone} = profile} =
             JidoChatBridge.fetch_profile(@lid, details(config))

    assert map_size(profile) == 1
  end

  test "absent additional identifiers preserve the existing map profile contract", %{
    config: config
  } do
    expect(ProfileAdapterMock, :get_user, fn @lid, _ ->
      {:ok, %{full_name: "Profile name", metadata: %{phone: @phone}}}
    end)

    assert {:ok,
            %{
              "display_name" => "Profile name",
              "phone" => @phone,
              "username" => nil,
              "email" => nil
            } = profile} = JidoChatBridge.fetch_profile(@lid, details(config))

    assert map_size(profile) == 4
  end

  test "profile enrichment links a verified alias to the existing Person without replacing the primary",
       %{
         config: config
       } do
    assert {:ok, original} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @lid
             })

    expect_profile(%{phone: @phone, additional_identifiers: [@pn]}, 2)
    message = incoming(config)

    assert {:ok, person} = IdentityResolver.resolve(message, [])
    assert person.id == original.id
    assert person.phone == @phone
    assert message.author_id == @lid

    assert MapSet.new(Enum.map(person.channels, & &1.channel_identifier)) ==
             MapSet.new([@lid, @pn])

    assert Enum.all?(person.channels, fn channel ->
             channel.person_id == person.id and channel.platform == "whatsapp" and
               channel.channel_config_id == config.id
           end)

    assert {:ok, repeated} = IdentityResolver.resolve(message, [])
    assert repeated.id == person.id
    assert Enum.map(repeated.channels, & &1.id) == Enum.map(person.channels, & &1.id)
  end

  test "unknown mapping leaves LID-only discovery successful without inventing a phone or alias",
       %{
         config: config
       } do
    expect_profile(%{phone: nil})
    assert {:ok, person} = IdentityResolver.resolve(incoming(config), [])
    assert person.phone == nil
    assert [%{channel_identifier: @lid}] = person.channels
  end

  test "late mapping enriches the same incomplete LID-only Person on a later message", %{
    config: config
  } do
    expect_profile(%{phone: nil})
    assert {:ok, original} = IdentityResolver.resolve(incoming(config), [])
    assert original.incomplete

    expect_profile(%{phone: @phone, additional_identifiers: [@pn]})
    assert {:ok, enriched} = IdentityResolver.resolve(incoming(config), [])
    assert enriched.id == original.id
    assert enriched.phone == @phone
    assert length(enriched.channels) == 2
  end

  test "a profile alias owned by another Person fails without stealing or merging", %{
    config: config
  } do
    assert {:ok, owner} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @pn
             })

    assert {:ok, original} =
             People.find_or_create_from_channel("whatsapp", %{
               channel_config_id: config.id,
               channel_id: @lid
             })

    expect_profile(%{phone: @phone, additional_identifiers: [@pn]})
    assert {:error, conflict} = IdentityResolver.resolve(incoming(config), [])
    assert errors_on(conflict).channel_identifier != []
    assert People.get_person!(original.id).phone == nil
    assert [%{channel_identifier: @lid}] = People.list_person_channels(original.id)
    assert [%{channel_identifier: @pn}] = People.list_person_channels(owner.id)
  end

  test "malformed alias metadata is rejected by discovery rather than creating an identity", %{
    config: config
  } do
    for malformed <- [[123], false, @pn] do
      expect_profile(%{additional_identifiers: malformed})

      assert {:error, :invalid_additional_identifiers} =
               IdentityResolver.resolve(incoming(config), [])

      assert {:error, :not_found} = People.match_by_channel("whatsapp", @lid, config.id)
    end
  end

  defp expect_profile(metadata, count \\ 1) do
    expect(ProfileAdapterMock, :get_user, count, fn @lid, _opts ->
      {:ok, UserInfo.new(%{id: @lid, metadata: metadata})}
    end)
  end

  defp details(config) do
    %{provider: "whatsapp", channel_config_id: config.id, url: config.url, token: config.token}
  end

  defp incoming(config) do
    Incoming.new(%{
      provider: :whatsapp,
      author_id: @lid,
      author_name: "Sender",
      channel_id: @lid,
      content: "hello",
      is_dm: true,
      routing_context: %{channel_config_id: config.id}
    })
  end
end
