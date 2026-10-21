defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.Communication.ChannelEnablePolicy

  test "WhatsApp enable availability requires a super-admin without restricting disable" do
    for provider <- [:whatsapp, "whatsapp"] do
      for user <- [nil, %{}, %{role: %{name: "admin"}}, %{role: %{name: "staff"}}] do
        assert ChannelEnablePolicy.disabled_reason(%{provider: provider, enabled: false}, user) ==
                 "Only super admins can enable a WhatsApp account."

        assert is_nil(
                 ChannelEnablePolicy.disabled_reason(%{provider: provider, enabled: true}, user)
               )
      end

      assert is_nil(
               ChannelEnablePolicy.disabled_reason(
                 %{provider: provider, enabled: false},
                 %{role: %{name: "super_admin"}}
               )
             )
    end
  end

  property "other adapters retain their toggle availability regardless of role" do
    check all(
            provider <- string(:alphanumeric) |> filter(&(&1 != "whatsapp")),
            enabled <- boolean(),
            user <-
              member_of([nil, %{}, %{role: %{name: "staff"}}, %{role: %{name: "super_admin"}}])
          ) do
      assert is_nil(
               ChannelEnablePolicy.disabled_reason(%{provider: provider, enabled: enabled}, user)
             )
    end
  end

  test "enabled WhatsApp profiles open their connection flow" do
    for provider <- [:whatsapp, "whatsapp"] do
      assert :open_connection = ChannelEnablePolicy.after_enable(provider, %{enabled: true})
      assert :proceed = ChannelEnablePolicy.after_enable(provider, %{enabled: false})
    end
  end

  property "other adapters preserve the default presentation" do
    check all(
            provider <- string(:alphanumeric) |> filter(&(&1 != "whatsapp")),
            enabled <- boolean()
          ) do
      assert :proceed = ChannelEnablePolicy.after_enable(provider, %{enabled: enabled})
    end
  end
end

defmodule ZaqWeb.Live.BO.Communication.ChannelDisablePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.Communication.ChannelDisablePolicy

  test "WhatsApp disable explains logout and relinking" do
    assert {:confirm, message} = ChannelDisablePolicy.before_disable("whatsapp", %{enabled: true})
    assert message =~ "log out this profile"
    assert message =~ "link it again"
  end

  property "all other adapters preserve immediate toggling" do
    check all(
            provider <-
              member_of(
                ~w(mattermost telegram slack discord teams email:smtp email:imap web_widget)
              ),
            enabled <- boolean()
          ) do
      assert :proceed = ChannelDisablePolicy.before_disable(provider, %{enabled: enabled})
    end
  end

  test "enabling WhatsApp proceeds without confirmation" do
    assert :proceed = ChannelDisablePolicy.before_disable("whatsapp", %{enabled: false})
  end
end
