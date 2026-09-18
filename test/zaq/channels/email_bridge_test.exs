defmodule Zaq.Channels.EmailBridgeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Channels.EmailBridge.SmtpSender
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  defmodule TestConfig do
    def get(:zaq, key, default, opts), do: Keyword.get(opts, key, default)
  end

  setup do
    owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  defmodule SmtpSenderStub do
    def send_notification(recipient, payload, details) do
      send(self(), {:smtp_notification, recipient, payload, details})
      :ok
    end
  end

  defmodule SmtpErrorStub do
    def send_notification(_recipient, _payload, _details), do: {:error, :smtp_unavailable}
  end

  defmodule DynamicAdapterStub do
    def to_internal(payload, connection_details) do
      send(self(), {:dynamic_adapter_called, payload, connection_details})

      %Zaq.Engine.Messages.Incoming{
        content: "ok",
        channel_id: "INBOX",
        provider: :"email:imap",
        metadata: %{}
      }
    end
  end

  defmodule MaterializationAdapterStub do
    def download_attachment(config, request) do
      send(self(), {:download_attachment, config, request})
      Process.get(:email_materialization_download_result, {:ok, "downloaded-bytes"})
    end
  end

  defmodule MailboxTupleAdapterStub do
    def list_mailboxes(_config) do
      {:ok,
       [
         {"INBOX", "/", ["\\HasNoChildren"]},
         {"HR", "/", ["\\HasChildren"]},
         {"INBOX", "/", ["\\HasNoChildren"]}
       ]}
    end
  end

  defmodule LegacyMailboxTupleAdapterStub do
    def list_mailboxes(_config) do
      {:error,
       {:list_mailboxes_failed,
        {:ok,
         [
           {"INBOX", "/", ["\\HasNoChildren"]},
           {"HR", "/", ["\\HasChildren"]},
           {"INBOX", "/", ["\\HasNoChildren"]}
         ]}}}
    end
  end

  defmodule MailboxErrorAdapterStub do
    def list_mailboxes(_config), do: {:error, :imap_unreachable}
  end

  defmodule CaptureMailboxAdapterStub do
    def list_mailboxes(config) do
      send(self(), {:captured_mailbox_config, config})
      {:ok, ["INBOX"]}
    end
  end

  defmodule MixedMailboxAdapterStub do
    def list_mailboxes(_config) do
      {:ok, [%{mailbox: "INBOX"}, %{"mailbox" => "Support"}, "Sales", :skip]}
    end
  end

  defmodule RuntimeErrorAdapterStub do
    def runtime_specs(_config, _bridge_id, _opts), do: {:error, :runtime_failed}
  end

  defmodule RuntimeInvalidSpecAdapterStub do
    def runtime_specs(_config, _bridge_id, _opts) do
      {:ok, {nil, [%{id: :invalid_listener}]}}
    end
  end

  defmodule RuntimeListenerStub do
    use GenServer

    def start_link(opts) when is_list(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      mailbox = Keyword.fetch!(opts, :mailbox)
      send(test_pid, {:runtime_listener_started, mailbox, self()})
      {:ok, %{mailbox: mailbox}}
    end
  end

  defmodule RuntimeAdapterStub do
    def runtime_specs(config, bridge_id, _opts) do
      selected =
        config
        |> Map.get(:selected_mailboxes, [])
        |> List.wrap()

      listeners =
        Enum.map(selected, fn mailbox ->
          %{
            id: {RuntimeListenerStub, "#{bridge_id}:#{mailbox}"},
            start: {RuntimeListenerStub, :start_link, [[mailbox: mailbox, test_pid: self()]]},
            restart: :permanent,
            type: :worker
          }
        end)

      {:ok, {nil, listeners}}
    end
  end

  defmodule RuntimeCaptureAdapterStub do
    def runtime_specs(config, _bridge_id, opts) do
      send(self(), {:captured_runtime_config, config})
      send(self(), {:captured_runtime_opts, opts})
      {:ok, {nil, []}}
    end
  end

  defmodule IncomingAdapterStub do
    def to_internal(_payload, _connection_details) do
      %Zaq.Engine.Messages.Incoming{
        content: "incoming",
        channel_id: "author@example.com",
        author_id: "author@example.com",
        provider: :"email:imap",
        metadata: %{"email" => %{}}
      }
    end
  end

  defmodule IncomingAdapterErrorStub do
    def to_internal(_payload, _connection_details), do: {:error, :invalid_payload}
  end

  defmodule PipelineOkStub do
    def run(_incoming, _opts) do
      %Zaq.Engine.Messages.Outgoing{
        body: "outgoing",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Pipeline subject"}
      }
    end
  end

  defmodule PipelineUnexpectedValueStub do
    def run(_incoming, _opts), do: :queued
  end

  defmodule RouterOkStub do
    def deliver(_outgoing), do: :ok
  end

  defmodule ApiDeliveryNodeRouterStub do
    def dispatch(event) do
      if event.opts[:action] == :deliver_outgoing do
        send(self(), {:api_delivery_event, event})
      end

      %{event | response: :ok}
    end
  end

  defmodule RouterErrorStub do
    def deliver(_outgoing), do: {:error, :delivery_failed}
  end

  defmodule RouterUnexpectedStub do
    def deliver(_outgoing), do: :queued
  end

  defmodule ConversationsOkStub do
    def persist_from_incoming(_incoming, _metadata), do: :ok
  end

  defmodule ConversationsErrorStub do
    def persist_from_incoming(_incoming, _metadata), do: {:error, :persist_failed}
  end

  defmodule NodeRouterOkStub do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      response =
        case event.opts[:action] do
          :route_incoming_message ->
            %Outgoing{
              body: "from-node-router",
              channel_id: event.request.channel_id,
              provider: :email
            }

          :run_pipeline ->
            %Outgoing{
              body: "from-node-router",
              channel_id: event.request.channel_id,
              provider: :email
            }

          :deliver_outgoing ->
            {:ok, %{message_id: "delivered@zaq.test"}}

          _ ->
            {:error, :unsupported}
        end

      %{event | response: response}
    end

    def fire(event) do
      send(self(), {:node_router_fire_event, event})
      event
    end
  end

  defmodule NodeRouterBadPipelineStub do
    def dispatch(event), do: %{event | response: :unexpected}
  end

  defmodule NodeRouterErrorPipelineStub do
    def dispatch(event), do: %{event | response: {:error, :pipeline_failed}}
  end

  defmodule CapturingNodeRouterStub do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      response =
        case event.opts[:action] do
          :route_incoming_message ->
            send(self(), {:node_router_route_incoming_event, event})

            %Outgoing{
              body: "captured",
              channel_id: event.request.channel_id,
              provider: :email,
              metadata: %{answer: "captured"}
            }

          :run_pipeline ->
            send(self(), {:node_router_run_pipeline_event, event})

            %Outgoing{
              body: "captured",
              channel_id: event.request.channel_id,
              provider: :email,
              metadata: %{answer: "captured"}
            }

          :deliver_outgoing ->
            :ok

          _ ->
            {:error, :unsupported}
        end

      %{event | response: response}
    end

    def fire(event) do
      send(self(), {:node_router_fire_event, event})
      event
    end
  end

  defp smtp_settings(overrides \\ %{}) do
    Map.merge(
      %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => nil,
        "password" => nil,
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      },
      overrides
    )
  end

  defp upsert_smtp_channel(attrs \\ %{}) do
    defaults = %{
      name: "Email SMTP",
      kind: "retrieval",
      enabled: true,
      settings: smtp_settings()
    }

    assert {:ok, _channel} =
             ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    :ok
  end

  describe "to_internal/2" do
    test "maps imap payload into Incoming message" do
      opts = [config: TestConfig]
      config = %{id: 42}

      payload = %{
        "body_text" => "hello from imap",
        "body_html" => "<p>hello from imap</p>",
        "from" => %{"address" => "alice@example.com", "name" => "Alice"},
        "subject" => "Hello",
        "message_id" => "<msg-1@example.com>",
        "in_reply_to" => "<root@example.com>",
        "references" => "<a@example.com> <root@example.com>",
        "attachments" => [
          %{
            "filename" => "manual.pdf",
            "content_type" => "application/pdf",
            "download_ref" => "att-1"
          }
        ]
      }

      assert incoming =
               EmailBridge.to_internal(
                 payload,
                 %{
                   config: config,
                   mailbox: "INBOX",
                   adapter: Zaq.Channels.EmailBridge.ImapAdapter
                 },
                 opts
               )

      assert incoming.content == "Subject: Hello\n\nhello from imap"
      assert incoming.channel_id == "alice@example.com"
      assert incoming.author_id == "alice@example.com"
      assert incoming.author_name == "Alice"
      assert incoming.thread_id == "a@example.com"
      assert incoming.message_id == "<msg-1@example.com>"
      assert incoming.provider == :"email:imap"
      assert incoming.routing_context.channel_config_id == 42
      assert incoming.metadata["email"]["html_body"] == "<p>hello from imap</p>"

      assert incoming.attachments == []
      refute Map.has_key?(incoming.metadata["email"], "attachments")
    end

    test "materializes email attachments through configured IMAP adapter" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          email: %{adapter: MaterializationAdapterStub}
        })

      config = %{id: 3, provider: "email:imap"}

      request = %{
        "reference" => "email:3:10:42:2.1",
        "mailbox" => "INBOX",
        "uid_validity" => 10,
        "uid" => 42,
        "section" => "2.1",
        "name" => "invoice.pdf",
        "mime_type" => "application/pdf"
      }

      assert {:ok, %{record: record}} = EmailBridge.materialize_record(config, request, %{}, opts)
      assert record.id == "email:3:10:42:2.1"
      assert record.content == "downloaded-bytes"
      assert record.name == "invoice.pdf"
      assert record.mime_type == "application/pdf"
      assert record.attributes["encoding"] == "binary"

      assert_received {:download_attachment, ^config, ^request}
    end

    test "rejects invalid adapter download content" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, {:ok, :not_binary})

      config = %{id: 3, provider: "email:imap"}
      request = %{"mailbox" => "INBOX", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :invalid_media_content} =
               EmailBridge.materialize_record(config, request, %{}, opts)

      assert_received {:download_attachment, ^config, ^request}
    end

    test "returns unexpected adapter download result" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, :unexpected_download_result)

      config = %{id: 3, provider: "email:imap"}
      request = %{"mailbox" => "INBOX", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :unexpected_download_result} =
               EmailBridge.materialize_record(config, request, %{}, opts)
    end

    test "rejects invalid materialization argument shapes without resolving an adapter" do
      opts = [config: TestConfig]

      assert {:error, :invalid_media_request} =
               EmailBridge.materialize_record(:bad, %{}, %{}, opts)

      assert {:error, :invalid_media_request} =
               EmailBridge.materialize_record(%{}, :bad, %{}, opts)

      assert {:error, :invalid_media_request} =
               EmailBridge.materialize_record(%{}, %{}, :bad, opts)

      refute_received {:download_attachment, _, _}
    end

    test "returns unsupported for an adapter without attachment downloads" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: DynamicAdapterStub}})

      assert {:error, :unsupported} =
               EmailBridge.materialize_record(
                 %{provider: "email:imap"},
                 %{"mailbox" => "INBOX"},
                 %{},
                 opts
               )
    end

    test "generates attachment id when reference is absent" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      config = %{id: 7, provider: "email:imap"}
      request = %{"channel_config_id" => 7, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:ok, %{record: %{id: "email:7:10:42:2.1"}}} =
               EmailBridge.materialize_record(config, request, %{}, opts)
    end

    test "accepts string attachment size at the configured limit" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, {:ok, "1234567"})

      config = %{id: 3, provider: "email:imap"}
      request = %{"size" => "7", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:ok, %{record: %{content: "1234567"}}} =
               EmailBridge.materialize_record(
                 config,
                 request,
                 %{
                   config_opts: [max_media_bytes: 7]
                 },
                 opts
               )

      assert_received {:download_attachment, ^config, ^request}
    end

    test "ignores invalid attachment size strings" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      config = %{id: 3, provider: "email:imap"}

      for size <- ["7bytes", "-1"] do
        request = %{"size" => size, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

        assert {:ok, _} =
                 EmailBridge.materialize_record(
                   config,
                   request,
                   %{
                     config_opts: [max_media_bytes: 20]
                   },
                   opts
                 )
      end
    end

    test "allows attachment content when no size limit is configured" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      assert {:ok, _} =
               EmailBridge.materialize_record(
                 %{id: 3, provider: "email:imap"},
                 %{"size" => 999, "uid_validity" => 10, "uid" => 42, "section" => "2.1"},
                 %{config_opts: [max_media_bytes: nil]},
                 opts
               )
    end

    test "rejects oversized declared and downloaded attachment content" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      config = %{id: 3, provider: "email:imap"}
      request = %{"size" => 8, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :media_too_large} =
               EmailBridge.materialize_record(
                 config,
                 request,
                 %{
                   config_opts: [max_media_bytes: 7]
                 },
                 opts
               )

      refute_received {:download_attachment, _, _}

      Process.put(:email_materialization_download_result, {:ok, "12345678"})
      request = Map.put(request, "size", 7)

      assert {:error, :media_too_large} =
               EmailBridge.materialize_record(
                 config,
                 request,
                 %{
                   config_opts: [max_media_bytes: 7]
                 },
                 opts
               )

      assert_received {:download_attachment, ^config, ^request}
    end

    test "rejects non-IMAP configs for email attachment materialization" do
      opts = [config: TestConfig]

      assert {:error, :invalid_email_attachment_provider} =
               EmailBridge.materialize_record(%{provider: "email:smtp"}, %{}, %{}, opts)
    end

    test "dispatches to adapter passed through connection details" do
      opts = [config: TestConfig]
      payload = %{"body_text" => "hello"}
      details = %{adapter: DynamicAdapterStub, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details, opts)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end

    test "returns invalid payload error when args are not maps" do
      opts = [config: TestConfig]
      assert {:error, :invalid_email_payload} = EmailBridge.to_internal("bad", %{}, opts)
      assert {:error, :invalid_email_payload} = EmailBridge.to_internal(%{}, :bad, opts)
    end

    test "falls back to provider adapter from config when adapter key is absent" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: DynamicAdapterStub}
        })

      payload = %{"body_text" => "hello"}
      details = %{config: %{provider: "missing-provider"}, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details, opts)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end

    test "uses default email:imap provider when config is absent" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: DynamicAdapterStub}
        })

      payload = %{"body_text" => "hello"}
      details = %{mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details, opts)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end
  end

  describe "from_listener/3 via NodeRouter event dispatch" do
    test "returns :ok when NodeRouter provides pipeline/delivery/persist responses" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, NodeRouterOkStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
    end

    test "treats non-error route responses as acknowledged" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, NodeRouterBadPipelineStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
    end

    test "returns pipeline error when NodeRouter responds with {:error, reason}" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, NodeRouterErrorPipelineStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      log =
        capture_log(fn ->
          assert {:error, :pipeline_failed} =
                   EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "routes with email imap channel config id for provider rule lookup" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      provider_agent = insert_configured_agent(true)

      assert {:ok, config} =
               ChannelConfig.set_provider_default_agent_id(config, provider_agent.id)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert event.request.routing_context.channel_config_id == config.id

      assert %{
               source: :provider,
               configured_agent_id: configured_agent_id
             } = IncomingMessageRouting.resolve(event.request)

      assert configured_agent_id == provider_agent.id
    end

    test "runtime-normalized email imap config preserves channel config id for routing" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      normalized = ImapConfigHelpers.normalize_bridge_config(config)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(normalized, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert event.request.routing_context.channel_config_id == config.id
    end

    test "route_incoming_message event carries channel actor" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert event.actor == %{
               id: "author@example.com",
               name: nil,
               provider: :"email:imap"
             }
    end

    test "routes with global default when provider default is absent" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      global_agent = insert_configured_agent(true)
      :ok = Zaq.System.set_global_default_agent_id(global_agent.id)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert %{source: :global, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(event.request)

      assert configured_agent_id == global_agent.id
    end

    test "routes to default ZAQ agent when no explicit or global selection is configured" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      :ok = Zaq.System.set_global_default_agent_id(nil)

      config =
        insert_imap_channel_config(%{settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}})

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert %{source: :default_zaq_agent, configured_agent_id: nil} =
               IncomingMessageRouting.resolve(event.request)
    end

    test "keeps mailbox-specific agent routing when using runtime-prepared config" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      :ok = Zaq.System.set_global_default_agent_id(nil)

      config = %{
        provider: "email:imap",
        settings: %{
          "imap" => %{"selected_mailboxes" => ["INBOX"]}
        }
      }

      prepared = ImapConfigHelpers.normalize_bridge_config(config)
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(prepared, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}

      assert event.opts[:action] == :route_incoming_message
      assert event.request.routing_context.topic_id == "INBOX"
      refute Map.has_key?(event.assigns || %{}, "agent_selection")
    end

    test "NONE mailbox routing fires trigger event without agent dispatch" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = %{
        provider: "email:imap",
        settings: %{
          "imap" => %{"selected_mailboxes" => ["INBOX"]}
        }
      }

      prepared = ImapConfigHelpers.normalize_bridge_config(config)
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(prepared, payload, Keyword.merge(sink_opts, opts))
      assert_received {:node_router_route_incoming_event, event}
      assert event.request.content == "incoming"
      assert event.name == :incoming_message_routing_requested
      assert event.request.routing_context.topic_id == "INBOX"
      refute Map.has_key?(event.assigns || %{}, "agent_selection")
      refute_received {:node_router_run_pipeline_event, _}
    end
  end

  describe "email:smtp notification delivery" do
    test "delivers notifications using the email:smtp ChannelConfig" do
      upsert_smtp_channel()

      payload = %{"subject" => "Test subject", "body" => "Test body"}

      assert :ok = SmtpSender.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.to == [{"", "recipient@example.com"}]
      assert email.subject == "Test subject"
      assert email.from == {"ZAQ", "noreply@example.com"}
    end

    test "uses default sender when no email:smtp ChannelConfig exists" do
      payload = %{"subject" => "Fallback", "body" => "Hello"}

      assert :ok = SmtpSender.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "send_reply sets In-Reply-To and References headers" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg-2@example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Support request",
            "reply_from" => "julien@eweev.com",
            "headers" => %{"references" => "<msg-1@example.com> <msg-2@example.com>"}
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Support request"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<msg-2@example.com>"} in email.headers
      assert {"References", "<msg-1@example.com> <msg-2@example.com>"} in email.headers
    end

    test "send_reply uses SMTP from_name for IMAP replies" do
      opts = [config: TestConfig]

      upsert_smtp_channel(%{
        settings: smtp_settings(%{"from_name" => "Zaq local"})
      })

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg@example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Support request",
            "reply_from" => "support@example.com"
          }
        }
      }

      assert {:ok, _} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Support request"
      assert email.from == {"Zaq local", "support@example.com"}
      assert {"In-Reply-To", "<msg@example.com>"} in email.headers
    end

    test "reply without email metadata map does not set reply_from" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg@example.com>",
        metadata: %{"email" => "invalid", "subject" => "Question"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Question"
      assert email.from == {"ZAQ", "noreply@example.com"}
      assert {"In-Reply-To", "<msg@example.com>"} in email.headers
    end

    test "send_reply keeps subject unchanged for non-reply emails" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Notification body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Security alert"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Security alert"
      assert email.from == {"ZAQ", "noreply@example.com"}
      refute Enum.any?(email.headers, fn {k, _v} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply relays formatter format for html delivery" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "<h1>Title</h1><p><strong>hello</strong></p>",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Formatted", "format" => "html"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Formatted"
      assert email.html_body == "<h1>Title</h1><p><strong>hello</strong></p>"
      assert email.text_body == "Title\nhello"
    end

    test "send_reply keeps canonical message-id casing for threading headers" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<AbC123@Example.COM>",
        metadata: %{
          "email" => %{
            "subject" => "Threaded question",
            "reply_from" => "julien@eweev.com",
            "headers" => %{"references" => "<Root42@Example.com>"}
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Threaded question"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<AbC123@Example.COM>"} in email.headers
      assert {"References", "<Root42@Example.com> <AbC123@Example.COM>"} in email.headers
    end

    test "send_reply keeps already-prefixed subject and falls back to reply_from when from_email is blank" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg-3@example.com>",
        metadata: %{
          "subject" => "  Re: Existing thread  ",
          "from_email" => "   ",
          "from" => %{"name" => "  Agent Name  "},
          "email" => %{"reply_from" => "reply-fallback@example.com"}
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Existing thread"
      assert email.from == {"Agent Name", "reply-fallback@example.com"}
      assert {"In-Reply-To", "<msg-3@example.com>"} in email.headers
      assert {"References", "<msg-3@example.com>"} in email.headers
    end

    test "send_reply uses default reply subject for blank subject and dedupes list references" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "  <Root@Example.com>  ",
        metadata: %{
          "subject" => "   ",
          "email" => %{
            "headers" => %{
              "references" => [
                "<A@Example.com>",
                "A@Example.com",
                "  <B@Example.com>  ",
                nil,
                123
              ]
            }
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Re: Notification from ZAQ"
      assert {"In-Reply-To", "<Root@Example.com>"} in email.headers
      assert {"References", "<A@Example.com> <B@Example.com> <Root@Example.com>"} in email.headers
    end

    test "send_reply parses string references from incoming headers and appends in_reply_to once" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<Msg-2@Example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Thread follow-up",
            "headers" => %{
              "references" => " <Msg-1@Example.com>   Msg-2@Example.com  <Msg-1@Example.com> "
            }
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert {"In-Reply-To", "<Msg-2@Example.com>"} in email.headers
      assert {"References", "<Msg-1@Example.com> <Msg-2@Example.com>"} in email.headers
    end

    test "send_reply resolves sender from tuple and map address forms" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      tuple_outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Hello",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => {"  Tuple Name  ", " tuple@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(tuple_outgoing, %{}, opts)
      assert_receive {:email, tuple_email}
      assert tuple_email.from == {"Tuple Name", "tuple@example.com"}

      map_outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Hello",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => %{"address" => " addr@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(map_outgoing, %{}, opts)
      assert_receive {:email, map_email}
      assert map_email.from == {"ZAQ", "addr@example.com"}
    end

    test "send_reply uses nested email subject when top-level subject is absent" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"email" => %{"subject" => "Nested Subject"}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Nested Subject"
    end

    test "send_reply falls back to default subject when metadata is not a map" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: :invalid
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Notification from ZAQ"
    end

    test "send_reply does not treat blank in_reply_to as reply" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "   ",
        metadata: %{"subject" => "Plain subject"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.subject == "Plain subject"
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply prefers explicit from_name and from_email" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{
          "from_name" => "  Explicit Name ",
          "from_email" => " explicit@example.com ",
          "from" => %{"name" => "Ignored", "email" => "ignored@example.com"}
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.from == {"Explicit Name", "explicit@example.com"}
    end

    test "send_reply with non-binary thread metadata omits threading headers" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: 123,
        metadata: %{
          "subject" => "Threaded",
          "threading" => %{"references" => 999}
        }
      }

      assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
      assert receipt.anchor["in_reply_to"] == nil
      assert receipt.anchor["references"] == []
    end

    test "send_reply with nil in_reply_to omits threading headers" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: nil,
        metadata: %{"threading" => %{"references" => []}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply omits threading headers when message ids normalize to nil" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<>",
        metadata: %{"threading" => %{"references" => 123}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply derives sender from map and binary variants" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing_map = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => %{"email" => " map@example.com ", "name" => " Map Name "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing_map, %{}, opts)
      assert_receive {:email, email_map}
      assert email_map.from == {"Map Name", "map@example.com"}

      outgoing_binary = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => " binary@example.com "}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing_binary, %{}, opts)
      assert_receive {:email, email_binary}
      assert email_binary.from == {"ZAQ", "binary@example.com"}
    end

    test "send_reply derives sender from atom-key map variants" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{from: %{name: " Atom Name ", email: " atom@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.from == {"Atom Name", "atom@example.com"}
    end

    test "send_reply derives sender email from atom :address key" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{from: %{address: " atom-address@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "atom-address@example.com"}
    end

    test "send_reply ignores blank explicit from_name" do
      opts = [config: TestConfig]
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from_name" => "", "from_email" => "sender@example.com"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{}, opts)

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "sender@example.com"}
    end
  end

  describe "list_mailboxes/2" do
    test "normalizes tuple mailbox entries from adapter" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: MailboxTupleAdapterStub}
        })

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{}, opts)
    end

    test "accepts legacy wrapped list_mailboxes_failed ok payload" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: LegacyMailboxTupleAdapterStub}
        })

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{}, opts)
    end

    test "returns unsupported provider when provider is missing" do
      opts = [config: TestConfig]
      assert {:error, {:unsupported_provider, nil}} = EmailBridge.list_mailboxes(%{}, %{}, opts)
    end

    test "passes through adapter list_mailboxes errors" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: MailboxErrorAdapterStub}
        })

      assert {:error, :imap_unreachable} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{}, opts)
    end

    test "falls back to the real IMAP adapter when email config is absent" do
      opts = [config: TestConfig]
      channels = %{}
      opts = Keyword.put(opts, :channels, channels)

      assert {:error, :invalid_imap_url} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{}, opts)
    end

    test "normalizes nested IMAP settings into adapter config" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: CaptureMailboxAdapterStub}
        })

      config = %{
        provider: "unknown-provider",
        settings: %{
          "imap" => %{
            "username" => "imap-user",
            "port" => "993",
            "ssl" => false,
            "ssl_depth" => 4,
            "timeout" => 12_000,
            "selected_mailboxes" => [" INBOX ", "Support", ""]
          }
        },
        token: "imap-token"
      }

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{}, opts)
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.provider == "unknown-provider"
      assert prepared.username == "imap-user"
      assert prepared.port == "993"
      assert prepared.ssl == false
      assert prepared.ssl_depth == 4
      assert prepared.timeout == 12_000
      assert prepared.token == "imap-token"
      assert prepared.selected_mailboxes == ["INBOX", "Support"]
    end

    test "keeps selected_mailboxes list and tolerates non-map settings" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: CaptureMailboxAdapterStub}
        })

      config = %{provider: :"email:imap", settings: "bad", selected_mailboxes: ["INBOX", "Sales"]}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{}, opts)
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == ["INBOX", "Sales"]
    end

    test "normalization tolerates missing map values with string-key config" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: CaptureMailboxAdapterStub}
        })

      config = %{"provider" => "email:imap", "settings" => "not-a-map"}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{}, opts)
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == []
    end

    test "normalization handles non-map imap settings" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: CaptureMailboxAdapterStub}
        })

      config = %{provider: "email:imap", settings: %{"imap" => "oops"}}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{}, opts)
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == []
    end

    test "accepts atom provider key" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: MailboxTupleAdapterStub}
        })

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: :"email:imap"}, %{}, opts)
    end

    test "normalizes map and string mailbox entries from adapter" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: MixedMailboxAdapterStub}
        })

      assert {:ok, ["INBOX", "Sales", "Support"]} =
               EmailBridge.list_mailboxes(%{provider: :"email:imap"}, %{}, opts)
    end
  end

  describe "from_listener/3" do
    test "processes inbound payload end-to-end" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterOkStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert :ok =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 Keyword.merge(
                   [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                   opts
                 )
               )
    end

    test "returns adapter conversion error" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterOkStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :invalid_payload} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     Keyword.merge(
                       [adapter: IncomingAdapterErrorStub, mailbox: "INBOX"],
                       opts
                     )
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "returns delivery error" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterErrorStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :delivery_failed} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     Keyword.merge(
                       [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                       opts
                     )
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "wraps unexpected direct pipeline value" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineUnexpectedValueStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterOkStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :queued} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     Keyword.merge(
                       [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                       opts
                     )
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "delivers outgoing through NodeRouter when router module is Channels Api" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, Zaq.Channels.Api)
      opts = Keyword.put(opts, :email_bridge_node_router_module, ApiDeliveryNodeRouterStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert :ok =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 Keyword.merge(
                   [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                   opts
                 )
               )

      assert_receive {:api_delivery_event, event}
      assert event.opts[:action] == :deliver_outgoing
      assert event.request.body == "outgoing"
      assert event.request.channel_id == "recipient@example.com"
    end

    test "ignores persistence module in bridge path" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterOkStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsErrorStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert :ok =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     Keyword.merge(
                       [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                       opts
                     )
                   )
        end)

      refute log =~ "Failed to process inbound message"
    end

    test "returns wrapped error for unexpected non-error pipeline chain value" do
      opts = [config: TestConfig]
      opts = Keyword.put(opts, :email_bridge_pipeline_module, PipelineOkStub)
      opts = Keyword.put(opts, :email_bridge_router_module, RouterUnexpectedStub)
      opts = Keyword.put(opts, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :queued} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     Keyword.merge(
                       [adapter: IncomingAdapterStub, mailbox: "INBOX"],
                       opts
                     )
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end
  end

  describe "start_runtime/1" do
    test "passes routing settings into runtime-prepared listener config" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: RuntimeCaptureAdapterStub}
        })

      config_id = System.unique_integer([:positive])

      config = %{
        id: config_id,
        provider: "email:imap",
        settings: %{
          "routing" => %{"default_agent_id" => 123},
          "imap" => %{
            "username" => "imap-user",
            "selected_mailboxes" => ["INBOX"],
            "agent_routing" => %{"mailboxes" => %{"INBOX" => 456}}
          }
        }
      }

      on_exit(fn ->
        _ = EmailBridge.stop_runtime(config)
      end)

      assert :ok = EmailBridge.start_runtime(config, opts)
      assert_receive {:captured_runtime_config, prepared}
      assert prepared.selected_mailboxes == ["INBOX"]
      assert prepared.settings["routing"]["default_agent_id"] == 123
      assert prepared.settings["imap"]["agent_routing"]["mailboxes"]["INBOX"] == 456
    end

    test "restarts running runtime to apply updated selected mailboxes" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: RuntimeAdapterStub}
        })

      config_id = System.unique_integer([:positive])
      bridge_id = "email:imap_#{config_id}"

      initial_config = %{
        id: config_id,
        provider: "email:imap",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      }

      updated_config =
        put_in(initial_config, [:settings, "imap", "selected_mailboxes"], ["Support", "Sales"])

      on_exit(fn ->
        _ = EmailBridge.stop_runtime(initial_config)
      end)

      assert :ok = EmailBridge.start_runtime(initial_config, opts)
      assert_receive {:runtime_listener_started, "INBOX", _pid}, 500

      assert {:ok, runtime} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)
      assert Enum.sort(Enum.map(runtime.listener_pids, &listener_mailbox/1)) == ["INBOX"]

      assert :ok = EmailBridge.start_runtime(updated_config, opts)
      assert_receive {:runtime_listener_started, "Support", _pid}, 500
      assert_receive {:runtime_listener_started, "Sales", _pid}, 500

      assert {:ok, refreshed_runtime} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

      assert Enum.sort(Enum.map(refreshed_runtime.listener_pids, &listener_mailbox/1)) ==
               ["Sales", "Support"]
    end

    test "returns adapter runtime error" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: RuntimeErrorAdapterStub}
        })

      assert {:error, :runtime_failed} =
               EmailBridge.start_runtime(
                 %{
                   id: 99,
                   provider: "email:imap",
                   settings: %{"imap" => %{}}
                 },
                 opts
               )
    end

    test "returns runtime start error when supervisor rejects listener specs" do
      opts = [config: TestConfig]

      opts =
        Keyword.put(opts, :channels, %{
          :email => %{adapter: RuntimeInvalidSpecAdapterStub}
        })

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   EmailBridge.start_runtime(
                     %{
                       id: System.unique_integer([:positive]),
                       provider: "email:imap",
                       settings: %{"imap" => %{}}
                     },
                     opts
                   )
        end)

      assert log =~ "invalid_child_spec"
    end
  end

  describe "stop_runtime/1" do
    test "returns :ok when runtime is not running" do
      assert :ok =
               EmailBridge.stop_runtime(%{
                 id: System.unique_integer([:positive]),
                 provider: "email:imap"
               })
    end
  end

  describe "config injection" do
    test "preserves errors from an injected SMTP sender" do
      outgoing = %Zaq.Engine.Messages.Outgoing{
        provider: :email,
        channel_id: "recipient@example.com",
        body: "Message",
        metadata: %{}
      }

      assert {:error, :smtp_unavailable} =
               EmailBridge.send_reply(outgoing, %{},
                 config: TestConfig,
                 email_bridge_smtp_module: SmtpErrorStub
               )
    end

    test "falls back to NodeRouter when the configured router does not implement deliver" do
      opts = [
        config: TestConfig,
        adapter: IncomingAdapterStub,
        email_bridge_pipeline_module: PipelineOkStub,
        email_bridge_router_module: DynamicAdapterStub,
        email_bridge_node_router_module: ApiDeliveryNodeRouterStub
      ]

      assert :ok =
               EmailBridge.from_listener(
                 %{provider: "email:imap"},
                 %{"body_text" => "hello"},
                 opts
               )

      assert_receive {:api_delivery_event, event}
      assert event.opts == [action: :deliver_outgoing]
      assert event.request.body == "outgoing"
    end

    test "uses the SMTP module from connection config opts" do
      outgoing = %Zaq.Engine.Messages.Outgoing{
        provider: :email,
        channel_id: "recipient@example.com",
        body: "Injected delivery",
        metadata: %{subject: "Subject"}
      }

      details = %{config_opts: [config: TestConfig, email_bridge_smtp_module: SmtpSenderStub]}

      assert {:ok, %{message_id: message_id}} = EmailBridge.send_reply(outgoing, details)
      assert_receive {:smtp_notification, "recipient@example.com", payload, %{}}
      assert payload["subject"] == "Subject"
      assert payload["body"] == "Injected delivery"
      assert payload["headers"]["Message-ID"] == "<#{message_id}>"
    end

    test "explicit opts override connection config opts" do
      details = %{
        config_opts: [config: TestConfig, channels: %{email: %{adapter: MailboxErrorAdapterStub}}]
      }

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, details,
                 channels: %{email: %{adapter: MailboxTupleAdapterStub}}
               )
    end

    test "materialization uses injected default byte limit from config_opts" do
      details = %{
        config_opts: [
          config: TestConfig,
          channels: %{email: %{adapter: MaterializationAdapterStub}},
          message_trace_artifact_max_bytes: 7
        ]
      }

      assert {:error, :media_too_large} =
               EmailBridge.materialize_record(%{provider: "email:imap"}, %{"size" => 8}, details)

      refute_received {:download_attachment, _, _}
    end

    test "runtime specs carry config overrides into the listener sink" do
      opts = [
        config: TestConfig,
        channels: %{email: %{adapter: RuntimeCaptureAdapterStub}},
        email_bridge_pipeline_module: PipelineOkStub,
        email_bridge_router_module: RouterOkStub
      ]

      config = %{
        id: System.unique_integer([:positive]),
        provider: "email:imap",
        config_opts: opts
      }

      assert {:ok, {nil, []}} = EmailBridge.build_runtime_specs(config)
      assert_receive {:captured_runtime_config, prepared}
      assert_receive {:captured_runtime_opts, runtime_opts}
      assert runtime_opts[:sink_mfa] == {EmailBridge, :from_listener, []}
      assert Keyword.delete(runtime_opts[:sink_opts], :bridge_id) == opts

      assert :ok =
               EmailBridge.from_listener(
                 prepared,
                 %{"body_text" => "hello"},
                 Keyword.put(runtime_opts[:sink_opts], :adapter, IncomingAdapterStub)
               )
    end
  end

  defp listener_mailbox(pid) when is_pid(pid) do
    pid
    |> :sys.get_state()
    |> Map.fetch!(:mailbox)
  end

  defp insert_imap_channel_config(attrs) do
    upsert_smtp_channel()

    defaults = %{
      name: "Email IMAP",
      provider: "email:imap",
      kind: "retrieval",
      url: "imap.example.com",
      token: "imap-secret",
      enabled: true,
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_configured_agent(active) do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Email Bridge Agent #{System.unique_integer([:positive, :monotonic])}",
        description: "",
        job: "Route email traffic",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: active,
        advanced_options: %{}
      })

    agent
  end
end
