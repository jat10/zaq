defmodule Zaq.Channels.Delivery.ApiExecutionTest do
  use Zaq.DataCase, async: true
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Channels.Api
  alias Zaq.Channels.Events
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.Materialization
  alias Zaq.NodeRouter
  alias Zaq.Test.{FileDeliveryAdapter, TextDeliveryAdapter}
  alias Zaq.TestSupport.OpenAIStub

  defmodule CompletionWorker do
    use Oban.Worker, queue: :default
    @impl true
    def perform(_job), do: :ok
  end

  setup do
    Code.ensure_loaded!(FileDeliveryAdapter)
    Code.ensure_loaded!(TextDeliveryAdapter)
    ctx = stored_channel_answer()

    config =
      ctx.config
      |> ChannelConfig.changeset(%{token: self() |> :erlang.pid_to_list() |> List.to_string()})
      |> Repo.update!()

    %{ctx | config: config}
  end

  test "real API resolves once, executes selected adapter and records canonical history with one callback",
       ctx do
    marker = Ecto.UUID.generate()

    outgoing = %{
      outgoing(ctx)
      | metadata:
          Map.put(outgoing(ctx).metadata, "on_reply", %{
            "module" => Atom.to_string(CompletionWorker),
            "args" => %{"marker" => marker}
          })
    }

    assert %{response: {:ok, %{message_id: id}}} = deliver(outgoing)
    assert_receive :adapter_requirements
    refute_received :adapter_requirements
    assert_receive {:adapter_upload, _}
    assert_receive {:adapter_send, "room", _, _}
    assert Repo.get!(Message, ctx.answer.id).metadata["delivery_confirmation"]["message_id"] == id
    jobs = Repo.all(from j in Oban.Job, where: fragment("?->>'marker' = ?", j.args, ^marker))
    assert [%{args: %{"post_id" => ^id}}] = jobs
    refute_received {:adapter_send, _, _, _}
  end

  test "missing file declarations continue with text without acquiring a discarded handle", ctx do
    {:ok, handle} =
      Materialization.issue("communication_media", %{
        "provider" => "mattermost",
        "reference" => "discarded",
        "source_author_id" => "owner",
        "channel_config_id" => ctx.config.id
      })

    outgoing = %{
      outgoing(ctx)
      | attachments: [%Record{id: "lazy", kind: :file, materialization_handle: handle}]
    }

    assert %{response: {:ok, _}} = deliver(outgoing, fixture_adapter: TextDeliveryAdapter)
    assert_receive {:adapter_send, "room", _, _}
    refute_received {:adapter_fetch_media, _}
    refute_received {:adapter_upload, _}

    assert [%{"stage" => "configuration"}] =
             Repo.get!(Message, ctx.answer.id).metadata["delivery_parts"]["parts"]
  end

  test "explicit false policy aborts unavailable requirements without a provider effect", ctx do
    ctx.config
    |> ChannelConfig.changeset(%{
      settings: %{"file_delivery" => %{"send_on_file_failure" => false}}
    })
    |> Repo.update!()

    assert %{response: {:error, _}} = deliver(outgoing(ctx), fixture_adapter: TextDeliveryAdapter)
    refute_received {:adapter_upload, _}
    refute_received {:adapter_send, _, _, _}
  end

  test "discarding unsupported files can finalize an existing text stream without a replacement send",
       ctx do
    outgoing = %{
      outgoing(ctx)
      | metadata: Map.put(outgoing(ctx).metadata, :message_id, "streamed")
    }

    assert %{response: {:ok, %{message_id: "streamed", action: :updated}}} =
             deliver(outgoing, fixture_adapter: TextDeliveryAdapter)

    assert_receive {:adapter_edit, "room", "streamed", _, _}
    refute_received {:adapter_send, _, _, _}
    refute_received {:adapter_upload, _}
  end

  test "integer stream IDs remain the same provider edit target", ctx do
    outgoing = %{
      outgoing(ctx)
      | metadata: Map.put(outgoing(ctx).metadata, :status_message_id, 123)
    }

    assert %{response: {:ok, %{message_id: "123", action: :updated}}} =
             deliver(outgoing, fixture_adapter: TextDeliveryAdapter)

    assert_receive {:adapter_edit, "room", "123", _, _}
    refute_received {:adapter_send, _, _, _}
  end

  test "invalid attachment metadata is reported without acquisition or publication", ctx do
    outgoing = %{outgoing(ctx) | attachments: [%Record{id: "bad", kind: :folder}]}
    assert %{response: {:error, %{reason: :invalid_plan}}} = deliver(outgoing)
    refute_received {:adapter_upload, _}
    refute_received {:adapter_send, _, _, _}

    assert [%{"reason" => "invalid_plan"}] =
             Repo.get!(Message, ctx.answer.id).metadata["delivery_parts"]["parts"]
  end

  defmodule UnavailableEngine do
    def dispatch(_event), do: exit(:engine_unavailable)
  end

  test "an Engine outage after provider success does not send again", ctx do
    assert %{response: {:ok, _}} = deliver(outgoing(ctx), delivery_node_router: UnavailableEngine)
    assert_receive {:adapter_upload, _}
    assert_receive {:adapter_send, _, _, _}
    refute_received {:adapter_upload, _}
    refute_received {:adapter_send, _, _, _}
    refute Repo.get!(Message, ctx.answer.id).metadata["delivery_confirmation"]
  end

  test "multi-part publication invokes completion only once with the confirmed answer ID", ctx do
    marker = Ecto.UUID.generate()
    base = outgoing(ctx)

    outgoing = %{
      base
      | attachments: for(index <- 0..2, do: %{hd(base.attachments) | id: "file-#{index}"}),
        metadata:
          Map.put(base.metadata, "on_reply", %{
            "module" => Atom.to_string(CompletionWorker),
            "args" => %{"marker" => marker}
          })
    }

    assert %{response: {:ok, %{message_id: id}}} = deliver(outgoing)
    assert_receive {:adapter_send, _, _, _}
    assert_receive {:adapter_send, _, _, _}
    refute_received {:adapter_send, _, _, _}

    assert [%{args: %{"post_id" => ^id}}] =
             Repo.all(from j in Oban.Job, where: fragment("?->>'marker' = ?", j.args, ^marker))
  end

  test "IMAP attachment replies use the committed selected SMTP connector and its policy" do
    smtp_server = start_supervised!({Zaq.Test.SmtpCapture, owner: self()})
    assert_receive {:smtp_listening, ^smtp_server, port}

    smtp =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Selected SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        url: "smtp://selected",
        token: "unused",
        settings: %{
          "relay" => "127.0.0.1",
          "port" => Integer.to_string(port),
          "tls" => "never",
          "from_email" => "selected@example.com",
          "file_delivery" => %{
            "max_attachments_per_message" => 2,
            "max_encoded_message_bytes" => 20_000,
            "send_on_file_failure" => false
          }
        }
      })
      |> Repo.insert!()

    imap =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Inbox",
        provider: "email:imap",
        kind: "retrieval",
        url: "imap://inbox",
        token: "unused",
        settings: %{"imap" => %{"smtp_config_id" => smtp.id, "selected_mailboxes" => ["INBOX"]}}
      })
      |> Repo.insert!()

    outgoing = %Outgoing{
      provider: :"email:imap",
      body: "**answer**",
      channel_id: "recipient@example.com",
      routing_context: %{channel_config_id: imap.id, conversation_type: :recipient_addressed},
      attachments: [%Record{id: "file", kind: :file, content: <<0, 255>>, name: "binary.dat"}]
    }

    event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

    assert %{
             response:
               {:ok, %{confirmation: :confirmed, audience: %{sender: "selected@example.com"}}}
           } = Api.handle_event(event, :deliver_outgoing, nil)

    assert_receive {:smtp_command, "MAIL FROM:<selected@example.com>\r\n"}
    assert_receive {:smtp_data, body}
    assert body =~ "AP8="

    bad = %{
      outgoing
      | attachments: [%Record{id: "lazy", kind: :file, materialization_handle: "invalid"}]
    }

    assert %{response: {:error, _}} =
             Api.handle_event(%{event | request: bad}, :deliver_outgoing, nil)

    assert_receive :smtp_connection
    refute_receive :smtp_connection, 50
  end

  test "materialization uses Event identity and ignores outgoing metadata permission claims",
       ctx do
    {_server, endpoint} =
      OpenAIStub.start!(fn _conn, _body -> {200, "acquired bytes"} end, self())

    ctx.config |> ChannelConfig.changeset(%{url: endpoint}) |> Repo.update!()

    {:ok, handle} =
      Materialization.issue("communication_media", %{
        "provider" => "mattermost",
        "reference" => "owned",
        "source_author_id" => "owner",
        "channel_config_id" => ctx.config.id,
        "size" => 14
      })

    outgoing = %{
      outgoing(ctx)
      | attachments: [%Record{id: "lazy", kind: :file, materialization_handle: handle}],
        metadata:
          Map.merge(outgoing(ctx).metadata, %{actor: %{id: "owner"}, skip_permissions: true})
    }

    assert %{response: {:ok, _}} = deliver(outgoing)
    refute_received {:adapter_fetch_media, _}
    refute_received {:adapter_upload, _}
    assert_receive {:adapter_send, _, _, _}

    next = stored_channel_answer(config: ctx.config)
    outgoing = %{outgoing | metadata: outgoing(next).metadata}
    assert %{response: {:ok, _}} = deliver(outgoing, actor: %{id: "owner"})
    assert_receive {:openai_request, "GET", _, _, _}
    assert_receive {:adapter_upload, _}
  end

  test "attachment events retain explicit identity and keep bytes off the global trigger stream",
       ctx do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    control = Event.new(%{marker: "subscription control"}, :engine)
    control_trace = control.trace_id
    NodeRouter.fire(control)
    assert_receive {:node_router_event, %Event{trace_id: ^control_trace}}
    secret = "PRIVATE-FILE-#{Ecto.UUID.generate()}"
    base = outgoing(ctx)
    outgoing = %{base | attachments: [%{hd(base.attachments) | content: secret}]}

    event =
      Events.build_deliver_outgoing_event(outgoing,
        actor: %{id: "owner"},
        event_opts: [config: FileDeliveryAdapter, confidential: false]
      )

    assert event.actor == %{id: "owner"}
    assert event.opts[:confidential]
    trace = event.trace_id
    assert %{response: {:ok, _}} = NodeRouter.dispatch(event)
    refute_received {:node_router_event, %Event{trace_id: ^trace}}

    for _ <- 1..10 do
      receive do
        {:node_router_event, published} -> refute inspect(published) =~ secret
      after
        0 -> :ok
      end
    end
  end

  test "partial uploads keep only confirmed files in normal history and group missing files once",
       ctx do
    ctx.config |> ChannelConfig.changeset(%{url: "partial"}) |> Repo.update!()
    original = outgoing(ctx)

    outgoing = %{
      original
      | attachments:
          for(
            index <- 0..3,
            do: %{hd(original.attachments) | id: "source-#{index}", name: "file-#{index}.dat"}
          )
    }

    assert %{response: {:ok, %{message_id: id}}} = deliver(outgoing)
    for _ <- 1..2, do: assert_receive({:adapter_upload, _})
    for _ <- 1..2, do: assert_receive({:adapter_send, "room", _, _})
    refute_received {:adapter_send, _, _, _}
    answer = Repo.get!(Message, ctx.answer.id)
    assert answer.external_message_id == id
    assert [%{"id" => "known-second", "name" => "file-1.dat"}] = answer.attachments

    assert [%{"attachment_refs" => [0]}, %{"attachment_refs" => [2]}] =
             answer.metadata["delivery_parts"]["parts"]

    assert Repo.aggregate(
             from(m in Message,
               where: not is_nil(m.external_message_id) and m.role == "assistant"
             ),
             :count
           ) == 2

    refute inspect(answer.attachments) =~ "source-"
  end

  test "an uncertain first publication promotes the next root once with the original canonical answer",
       ctx do
    ctx.config |> ChannelConfig.changeset(%{url: "uncertain-first"}) |> Repo.update!()
    original = outgoing(ctx)

    outgoing = %{
      original
      | attachments:
          for(
            name <- ["first.dat", "second.dat", "third.dat"],
            do: %{hd(original.attachments) | id: name, name: name}
          )
    }

    assert %{response: {:ok, %{message_id: id}}} = deliver(outgoing)
    assert_receive {:adapter_send, "room", "Stored answer", _}
    assert_receive {:adapter_send, "room", "Stored answer", opts}
    assert opts[:uploaded_files] == [%{id: "third.dat"}]
    refute_received {:adapter_send, _, _, _}
    answer = Repo.get!(Message, ctx.answer.id)
    assert answer.external_message_id == id
    assert answer.content == ctx.answer.content

    assert [%{"outcome" => "unconfirmed", "stage" => "publication"}] =
             answer.metadata["delivery_parts"]["parts"]

    assert Repo.aggregate(
             from(m in Message,
               where: not is_nil(m.external_message_id) and m.role == "assistant"
             ),
             :count
           ) == 1
  end

  test "abort stops after a later upload uncertainty without publishing an uploaded prefix",
       ctx do
    ctx.config
    |> ChannelConfig.changeset(%{
      url: "abort-late-upload",
      settings: %{"file_delivery" => %{"send_on_file_failure" => false}}
    })
    |> Repo.update!()

    original = outgoing(ctx)

    outgoing = %{
      original
      | attachments:
          for(
            name <- ["a.dat", "b.dat", "c.dat", "reject.dat"],
            do: %{hd(original.attachments) | id: name, name: name}
          )
    }

    assert %{response: {:error, %{outcome: :unconfirmed}}} = deliver(outgoing)
    for _ <- 1..2, do: assert_receive({:adapter_upload, _})
    refute_received {:adapter_send, _, _, _}
    answer = Repo.get!(Message, ctx.answer.id)
    assert answer.external_message_id == nil
    assert answer.metadata["delivery_parts"]["confirmed_message_count"] == 0
    assert answer.metadata["delivery_parts"]["confirmed_attachment_count"] == 0
  end

  test "concurrent attempts keep their selected connectors, bytes and persisted answers isolated",
       ctx do
    other = stored_channel_answer()

    other.config
    |> ChannelConfig.changeset(%{token: self() |> :erlang.pid_to_list() |> List.to_string()})
    |> Repo.update!()

    first = outgoing(ctx)

    second = %{
      outgoing(other)
      | attachments: [%{hd(first.attachments) | content: "second attempt"}]
    }

    tasks = for outgoing <- [first, second], do: Task.async(fn -> deliver(outgoing) end)

    assert [%{response: {:ok, %{message_id: a}}}, %{response: {:ok, %{message_id: b}}}] =
             Task.await_many(tasks)

    assert a != b
    assert Repo.get!(Message, ctx.answer.id).external_message_id == a
    assert Repo.get!(Message, other.answer.id).external_message_id == b
    assert_receive {:adapter_upload, request_a}
    assert_receive {:adapter_upload, request_b}

    assert Enum.sort(Enum.map([request_a, request_b], &hd(&1.files).data)) == [
             "file bytes",
             "second attempt"
           ]

    refute_received {:adapter_upload, _}
  end

  test "confirmed history records acquired byte size rather than stale source size metadata",
       ctx do
    original = outgoing(ctx)
    outgoing = %{original | attachments: [%{hd(original.attachments) | size: 1}]}
    assert %{response: {:ok, _}} = deliver(outgoing)
    assert [%{"size" => 10}] = Repo.get!(Message, ctx.answer.id).attachments
  end

  defp deliver(outgoing, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    event =
      Event.new(outgoing, :channels,
        actor: actor,
        opts:
          Keyword.merge(
            [action: :deliver_outgoing, config: FileDeliveryAdapter],
            Keyword.delete(opts, :actor)
          )
      )

    Api.handle_event(event, :deliver_outgoing, nil)
  end

  defp outgoing(ctx),
    do: %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: ctx.answer.content,
      routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room},
      metadata: %{
        user_message_id: ctx.input.id,
        assistant_message_id: ctx.answer.id,
        persisted_assistant_message_id: ctx.answer.id
      },
      attachments: [%Record{id: "file", kind: :file, content: "file bytes", name: "file.dat"}]
    }
end
