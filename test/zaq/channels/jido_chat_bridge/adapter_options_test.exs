defmodule Zaq.Channels.JidoChatBridge.AdapterOptionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.JidoChatBridge.AdapterOptions
  alias Zaq.Engine.ChannelConfig

  @default_providers [:mattermost, :discord, :telegram, "mattermost", "discord", "telegram"]

  describe "build/2 default credential shape" do
    test "declared upload ceilings are forwarded for other adapters while ZAQ policy stays local" do
      opts =
        AdapterOptions.build(:discord, %{
          url: "local",
          token: "private",
          attachment_failure_policy: :abort,
          settings: %{"max_file_size" => 1024, "max_upload_request_size" => 2048}
        })

      assert opts[:max_file_size] == 1024
      assert opts[:max_upload_request_size] == 2048
      refute Keyword.has_key?(opts, :attachment_failure_policy)
    end

    property "shared connection options are forwarded uniformly for every provider" do
      check all(
              file_limit <- integer(1..1_000_000),
              upload_limit <- integer(1..1_000_000)
            ) do
        for provider <- @default_providers,
            connection <- [
              %{
                url: "local",
                token: "private",
                transport: __MODULE__,
                attachment_failure_policy: :abort,
                max_upload_request_size: upload_limit,
                settings: %{
                  "max_file_size" => file_limit,
                  "max_upload_request_size" => upload_limit + 1
                }
              },
              %{
                "url" => "local",
                "token" => "private",
                "transport" => __MODULE__,
                "attachment_failure_policy" => :abort,
                "settings" => %{
                  "max_file_size" => file_limit,
                  "max_upload_request_size" => upload_limit
                }
              }
            ] do
          assert AdapterOptions.build(provider, connection) == [
                   max_upload_request_size: upload_limit,
                   max_file_size: file_limit,
                   transport: __MODULE__,
                   url: "local",
                   token: "private"
                 ]
        end
      end
    end

    test "connector file limit reaches adapter opts for every provider" do
      for provider <- @default_providers do
        config = %ChannelConfig{
          provider: to_string(provider),
          url: "https://example.test",
          token: "test-token",
          settings: %{"max_file_size" => 307_200}
        }

        details = Bridge.fetch_connection_details_for_config(config)
        opts = AdapterOptions.build(provider, details)
        assert opts[:max_file_size] == 307_200
        assert opts[:url] == config.url
        assert opts[:token] == config.token
        assert AdapterOptions.build(provider, config) == opts
      end
    end

    test "default providers always receive exactly url then token" do
      check all(
              provider <- member_of(@default_providers),
              url <- one_of([constant(nil), string(:printable, max_length: 40)]),
              token <- one_of([constant(nil), string(:alphanumeric, max_length: 40)])
            ) do
        assert AdapterOptions.build(provider, %{url: url, token: token}) ==
                 [url: url, token: token]
      end
    end

    test "reads a channel config struct" do
      config = %ChannelConfig{
        provider: "mattermost",
        url: "https://mm.example.test",
        token: "abc"
      }

      assert AdapterOptions.build(config.provider, config) ==
               [url: "https://mm.example.test", token: "abc"]
    end

    test "reads string-keyed connection maps" do
      assert AdapterOptions.build("telegram", %{
               "url" => "https://tg.example.test",
               "token" => "s"
             }) ==
               [url: "https://tg.example.test", token: "s"]
    end

    test "keeps missing credentials as nil values" do
      assert AdapterOptions.build(:discord, %{}) == [url: nil, token: nil]
    end
  end
end
