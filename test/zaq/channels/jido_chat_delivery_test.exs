defmodule Zaq.Channels.JidoChatDeliveryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.Mattermost.Adapter
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.Api

  alias Zaq.Channels.{
    DeliveryAttachments,
    DeliveryError,
    DeliveryExecutor,
    EmailBridge,
    JidoChatBridge
  }

  alias Zaq.Channels.JidoChatBridge.AdapterOptions
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Engine.{ChannelConfig, Events, PeopleAuthGateway}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Event
  alias Zaq.Events.TrustedContext
  alias Zaq.TestSupport.DeliveryTestOwner
  alias Zaq.TestSupport.OpenAIStub

  defmodule FileTransport do
    alias Jido.Chat.Mattermost.Transport.ReqClient

    def prepare_upload(channel, files, opts) do
      with {:ok, prepared} <- ReqClient.prepare_upload(channel, files, opts),
           do: {:ok, Map.put(prepared, :inputs, files)}
    end

    def upload_prepared(prepared, opts),
      do: upload_files(prepared.channel_id, prepared.inputs, opts)

    def upload_files(channel, [file], opts) do
      send(DeliveryTestOwner.pid(), {:file_upload, channel, file, opts})

      case URI.parse(opts[:url]).path do
        "/reported_upload_error" ->
          {:error, DeliveryTestOwner.get({__MODULE__, :error})}

        "/upload_failed" ->
          {:error, :upload_failed}

        "/size_rejected" ->
          {:error, {413, %{"message" => "private-provider-detail"}}}

        "/upload_timeout" ->
          {:error, :timeout}

        path when path in ["/notice_failed", "/http_upload_failed"] ->
          {:error, {400, %{"message" => "private-provider-detail"}}}

        path when path in ["/notice_raised", "/notice_exit"] ->
          {:error, :upload_failed}

        _ ->
          {:ok, %{"file_infos" => [%{"id" => "upload-id", "name" => file.filename}]}}
      end
    end

    def edit_message(channel, id, text, opts) do
      if URI.parse(opts[:url]).path == "/reported_publication_error" do
        send(DeliveryTestOwner.pid(), {:file_edit, channel, id, text, opts})
        {:error, DeliveryTestOwner.get({__MODULE__, :error})}
      else
        ReqClient.edit_message(channel, id, text, opts)
      end
    end

    def send_message(channel, text, opts) do
      send(DeliveryTestOwner.pid(), {:file_post, channel, text, opts})

      case URI.parse(opts[:url]).path do
        "/reported_publication_error" ->
          {:error, DeliveryTestOwner.get({__MODULE__, :error})}

        "/post_failed" ->
          {:error, {500, %{"message" => "private-provider-detail"}}}

        "/post_timeout" ->
          {:error, %Req.TransportError{reason: :timeout}}

        "/missing_post_id" ->
          {:ok, %{"channel_id" => channel, "file_ids" => opts[:file_ids]}}

        _ ->
          {:ok,
           %{"id" => "final-post-id", "channel_id" => channel, "file_ids" => opts[:file_ids]}}
      end
    end
  end

  defmodule DeliveryBridge do
    alias Zaq.Channels.Bridge
    alias Zaq.Channels.JidoChatDeliveryTest.FileTransport

    defdelegate bridge_for(provider), to: Bridge
    defdelegate fetch_channel_config(provider, id), to: Bridge

    def fetch_connection_details_for_config(config) do
      config
      |> Bridge.fetch_connection_details_for_config()
      |> Map.put(:transport, FileTransport)
    end
  end

  defmodule FailingEditAdapter do
    defdelegate send_file(channel, file, opts), to: Adapter

    def edit_message(channel, message_id, text, opts) do
      send(DeliveryTestOwner.pid(), {:file_status, channel, message_id, text, opts})

      case URI.parse(opts[:url]).path do
        "/notice_failed" -> {:error, :notice_failed}
        "/notice_raised" -> raise "status failed"
        "/notice_exit" -> exit(:status_failed)
      end
    end
  end

  defmodule FileReplyWorker do
    use Oban.Worker, queue: :default
    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule ExitingReplyWorker do
    def new(_args), do: exit(:callback_failed)
  end

  setup do
    Process.put(:batch_post_counter, :atomics.new(1, []))
    Code.ensure_loaded!(Adapter)
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      email: %{bridge: EmailBridge},
      mattermost: %{bridge: JidoChatBridge, adapter: Adapter}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, registry: previous}
  end

  test "strict policy rejects unresolved transport requirements before materialization" do
    adapter = Jido.Chat.Discord.Adapter
    assert Jido.Chat.Adapter.capabilities(adapter).edit_message == :native
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :discord, %{adapter: adapter, bridge: JidoChatBridge})
    )

    outgoing = %{
      file_outgoing()
      | provider: :discord,
        delivery: %{
          file_outgoing().delivery
          | attachments: [
              %{
                hd(file_outgoing().delivery.attachments)
                | content: nil,
                  materialization_handle: "invalid-private-handle"
              }
            ]
        }
    }

    assert {:error,
            %DeliveryError{
              reason: :invalid_transport_requirements,
              delivery: :not_sent
            }} =
             JidoChatBridge.send_reply(outgoing, %{
               url: "https://example.test",
               token: "private",
               settings: %{"send_on_file_failure" => false}
             })

    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "ZAQ applies explicit policy to attachment create and edit while uploading once" do
    for message_id <- [nil, "status-id"] do
      outgoing = %{file_outgoing() | metadata: %{message_id: message_id}}
      connection = with_policy(file_connection(), :abort)
      assert {:ok, %{confirmation: :confirmed}} = JidoChatBridge.send_reply(outgoing, connection)
      assert_received {:file_upload, _, _, _}
      refute_received {:file_upload, _, _, _}

      if message_id,
        do:
          assert_received(
            {:file_status, _, "status-id", "File caption", [file_ids: ["upload-id"]]}
          ),
        else: assert_received({:file_post, _, "File caption", _})
    end
  end

  test "explicit continue records sanitized upload failure and publishes the original answer once" do
    connection = with_policy(file_connection("size_rejected"), :continue)

    assert {:ok,
            %{confirmation: :partial, messages: [receipt], failed_attachments: [failure]} = report} =
             JidoChatBridge.send_reply(file_outgoing(), connection)

    assert receipt.body == "File caption"
    assert failure.reason == {:http_error, 413}
    assert failure.stage in [:upload, :transport]
    refute inspect(report) =~ "private-provider-detail"
    assert_received {:file_upload, _, _, _}
    refute_received {:file_upload, _, _, _}
    assert_received {:file_post, _, "File caption", _}
    refute_received {:file_post, _, _, _}
  end

  for phase <- [:upload, :publication] do
    @tag :neutral_failure_report
    @tag failure_phase: phase
    test "neutral #{phase} failure categories survive create and edit reports without raw transport data",
         %{failure_phase: phase} do
      for {reason, category} <- [
            {{413, %{"message" => "private-provider-detail"}}, {:http_error, 413}},
            {{:http_error, 413}, {:http_error, 413}},
            {:timeout, :timeout},
            {%Req.TransportError{reason: :timeout}, :timeout},
            {%{token: "private-provider-detail"}, :attachment_delivery_failed}
          ],
          policy <- [:abort, :continue],
          message_id <- [nil, "status-id"] do
        Process.put({FileTransport, :error}, reason)
        outgoing = %{file_outgoing() | metadata: %{message_id: message_id}}

        connection =
          file_connection("reported_#{phase}_error")
          |> with_policy(policy)

        {result, logs} =
          with_log(fn -> JidoChatBridge.send_reply(outgoing, connection) end)

        report =
          if phase == :upload and policy == :continue do
            assert {:ok, %{confirmation: :partial, messages: [%{body: "File caption"}]} = report} =
                     result

            report
          else
            assert {:error, %DeliveryError{reason: {:attachment_delivery_failed, report}}} =
                     result

            assert report.messages == []
            assert report.delivery == if(phase == :upload, do: :not_sent, else: :unconfirmed)
            report
          end

        assert [%{reason: ^category, stage: stage, delivery: delivery}] =
                 report.failed_attachments

        assert stage == if(phase == :upload, do: :upload, else: :transport)
        assert delivery == if(phase == :upload, do: :not_sent, else: :unconfirmed)
        refute inspect(report) <> logs =~ "private-provider-detail"
        refute inspect(report) <> logs =~ "Req.TransportError"
        assert logs =~ inspect(category)
        assert_received {:file_upload, _, _, _}

        if phase == :upload and policy == :abort do
          refute_received {:file_post, _, _, _}
          refute_received {:file_status, _, _, _, _}
          refute_received {:file_edit, _, _, _, _}
        else
          if message_id do
            if phase == :publication,
              do: assert_received({:file_edit, _, "status-id", "File caption", _}),
              else: assert_received({:file_status, _, "status-id", "File caption", []})
          else
            assert_received {:file_post, _, "File caption", _}
          end
        end

        refute_received {:file_upload, _, _, _}
        refute_received {:file_post, _, _, _}
        refute_received {:file_status, _, _, _, _}
        refute_received {:file_edit, _, _, _, _}
      end
    end
  end

  test "policy-mode final create and edit failures stay unconfirmed without replacement delivery" do
    for message_id <- [nil, "status-id"] do
      outgoing = %{file_outgoing() | metadata: %{message_id: message_id}}

      assert {:error,
              %DeliveryError{
                delivery: :unconfirmed,
                reason:
                  {:attachment_delivery_failed,
                   %{stage: :transport, messages: [], delivery: :unconfirmed}}
              }} =
               deliver_outgoing(outgoing, file_connection("post_failed"))

      assert_received {:file_upload, _, _, _}

      if message_id,
        do:
          assert_received({:file_edit, _, "status-id", "File caption", [file_ids: ["upload-id"]]}),
        else: assert_received({:file_post, _, "File caption", _})

      refute_received {:file_upload, _, _, _}
      refute_received {:file_edit, _, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
    end
  end

  for {operation, message_id} <- [create: nil, edit: "existing-placeholder"] do
    @strict_operation operation
    @strict_message_id message_id

    test "persisted strict policy prevents #{@strict_operation} HTTP publication after a later upload group fails" do
      {:ok, person} = People.create_person(%{full_name: "Strict file delivery"})
      endpoint = strict_upload_server()

      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Strict file delivery",
          provider: "mattermost",
          kind: "retrieval",
          enabled: true,
          url: endpoint,
          token: "synthetic-token",
          settings: %{
            "max_file_size" => 64_000,
            "send_on_file_failure" => false
          }
        })
        |> Repo.insert!()

      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Other permissive connector",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: endpoint <> "/other-connector",
        token: "other-token",
        settings: %{
          "max_file_size" => 64_000,
          "send_on_file_failure" => true
        }
      })
      |> Repo.insert!()

      assert Repo.get!(ChannelConfig, config.id).settings["send_on_file_failure"] == false

      files =
        for index <- 1..11 do
          %Record{
            id: "file-#{index}",
            kind: :file,
            name: "file-#{index}.txt",
            mime_type: "text/plain",
            content: "selected file #{index}"
          }
        end

      outgoing = %{
        file_outgoing()
        | routing_context: %{channel_config_id: config.id},
          metadata: %{
            "message_id" => @strict_message_id,
            "on_reply" => %{
              "module" => Atom.to_string(FileReplyWorker),
              "args" => %{"strict_operation" => to_string(@strict_operation)}
            }
          },
          delivery: %{file_outgoing().delivery | attachments: files}
      }

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:unexpected_strict_confirmation, event})
        %{event | response: {:ok, event.request.receipt}}
      end)

      event =
        Event.new(outgoing, :channels,
          actor: %{person_id: person.id},
          opts: [action: :deliver_outgoing, delivery_node_router: Zaq.NodeRouterMock]
        )

      assert {:error,
              %DeliveryError{
                delivery: :not_sent,
                reason: {:attachment_delivery_failed, report}
              }} = Api.handle_event(event, :deliver_outgoing, nil).response

      assert report.stage == :upload
      assert report.messages == []

      assert Enum.map(report.uploaded_attachments, &Map.take(&1, [:filename, :id])) ==
               Enum.map(1..10, &%{filename: "file-#{&1}.txt", id: "uploaded-#{&1}"})

      assert Enum.map(report.uploaded_only, & &1.attachment_index) == Enum.to_list(0..9)

      assert [
               %{
                 filename: "file-11.txt",
                 delivery: :not_sent,
                 stage: :upload,
                 reason: {:http_error, 413}
               }
             ] =
               report.failed_attachments

      refute inspect(report) =~ "synthetic later-group upload rejection"

      assert_received {:openai_request, "POST", "/api/v4/files", "", first_upload}
      assert_received {:openai_request, "POST", "/api/v4/files", "", failed_upload}

      assert Regex.scan(~r/filename="([^"]+)"/, first_upload, capture: :all_but_first) ==
               Enum.map(1..10, &["file-#{&1}.txt"])

      assert Regex.scan(~r/filename="([^"]+)"/, failed_upload, capture: :all_but_first) ==
               [["file-11.txt"]]

      refute_received {:openai_request, "POST", "/api/v4/posts", _, _}
      refute_received {:openai_request, "PUT", _, _, _}
      refute_received {:openai_request, "PATCH", _, _, _}
      refute_received {:openai_request, _, _, _, _}
      refute_received {:unexpected_strict_confirmation, _}
      assert Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker) == []
      assert outgoing.delivery.attachments == files
      assert event.actor == %{person_id: person.id}
    end
  end

  for provider <- ["mattermost", :mattermost], thread_id <- [nil, "root-post"] do
    @provider provider
    @thread_id thread_id
    test "real Thread creates #{inspect(provider)} notification with root #{inspect(thread_id)}" do
      connection = http_server()

      outgoing = %Outgoing{
        provider: @provider,
        channel_id: "private-room",
        thread_id: @thread_id,
        body: "Synthetic private code 1234-5678",
        metadata: %{"subject" => "Sign-in"}
      }

      assert {:ok, %{confirmation: :confirmed, action: :created, message_id: "sent-post"}} =
               JidoChatBridge.send_reply(outgoing, connection)

      assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
      expected = %{"channel_id" => "private-room", "message" => outgoing.body}
      expected = if @thread_id, do: Map.put(expected, "root_id", @thread_id), else: expected
      assert Jason.decode!(body) == expected
    end
  end

  test "ordinary string-provider status edit uses the real adapter edit payload" do
    connection = http_server()

    outgoing = %Outgoing{
      provider: "mattermost",
      channel_id: "private-room",
      body: "Updated answer",
      metadata: %{message_id: "status-post"}
    }

    assert {:ok, %{confirmation: :confirmed, action: :updated, message_id: "status-post"}} =
             JidoChatBridge.send_reply(outgoing, connection)

    assert_received {:openai_request, "PUT", "/api/v4/posts/status-post", "", body}

    assert Jason.decode!(body) == %{
             "id" => "status-post",
             "channel_id" => "private-room",
             "message" => "Updated answer"
           }

    refute_received {:openai_request, "POST", _, _, _}
  end

  test "files use exact bytes, filename, MIME, caption and thread then return the final post ID" do
    bytes = <<255, 0, 128, 10>>
    outgoing = file_outgoing(bytes)

    assert {:ok, %{confirmation: :confirmed, action: :created, message_id: "final-post-id"}} =
             JidoChatBridge.send_reply(outgoing, file_connection())

    assert_received {:file_upload, "private-room", upload, upload_opts}
    assert upload == %{body: bytes, filename: "résumé.pdf", content_type: "application/pdf"}
    assert upload_opts[:thread_id] == "root-post"
    assert_received {:file_post, "private-room", "File caption", post_opts}
    assert post_opts[:thread_id] == "root-post"
    assert post_opts[:file_ids] == ["upload-id"]
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "confirmed files reuse incoming media descriptors for history on create and edit" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          case conn.request_path do
            "/api/v4/files" ->
              {201,
               %{
                 "file_infos" => [
                   %{
                     "id" => "channel-file",
                     "name" => "image.png",
                     "mime_type" => "image/png",
                     "size" => 2
                   }
                 ]
               }}

            _ ->
              {200,
               Map.merge(Jason.decode!(body), %{
                 "id" => "delivered-post",
                 "user_id" => "bot-author"
               })}
          end
        end,
        self()
      )

    start_supervised!(child)

    connection = %{
      url: String.trim_trailing(endpoint, "/v1"),
      max_file_size: 307_200,
      token: "synthetic-token"
    }

    for metadata <- [%{}, %{message_id: "delivered-post"}] do
      outgoing = %{
        file_outgoing()
        | metadata: metadata,
          routing_context: %{channel_config_id: 10}
      }

      assert {:ok, %{attachments: [descriptor]}} = JidoChatBridge.send_reply(outgoing, connection)
      assert descriptor["id"] == "channel-file"
      assert descriptor["mime_type"] == "image/png"
      source = descriptor["attributes"]["materialization_source"]["locator"]
      assert source["reference"] == "channel-file"
      assert source["source_author_id"] == "bot-author"
      assert source["source_message_id"] == "delivered-post"
      assert source["channel_config_id"] == "10"
      refute Map.has_key?(descriptor, "content")
      refute Map.has_key?(descriptor, "materialization_handle")

      assert {:ok, hydrated} =
               CommunicationMedia.hydrate(
                 %{
                   descriptor: descriptor,
                   transcript_id: Ecto.UUID.generate(),
                   message_id: Ecto.UUID.generate()
                 },
                 %{actor: %{person: %{id: 9}}}
               )

      assert hydrated.id == "channel-file"
      assert is_binary(hydrated.materialization_handle)
      assert hydrated.content == nil
    end
  end

  test "final attachments update the streamed answer instead of creating a duplicate post" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          case {conn.method, conn.request_path} do
            {"POST", "/api/v4/files"} ->
              {201, %{"file_infos" => [%{"id" => "uploaded-file"}]}}

            {"POST", "/api/v4/posts"} ->
              payload = Jason.decode!(body)
              id = if payload["file_ids"], do: "duplicate-post", else: "streamed-post"
              {201, Map.put(payload, "id", id)}

            {"PUT", "/api/v4/posts/streamed-post"} ->
              {200, Map.put(Jason.decode!(body), "id", "streamed-post")}
          end
        end,
        self()
      )

    start_supervised!(child)

    connection = %{
      url: String.trim_trailing(endpoint, "/v1"),
      max_file_size: 307_200,
      token: "synthetic-token"
    }

    outgoing = file_outgoing()

    assert {:ok, %{message_id: "streamed-post"}} =
             JidoChatBridge.upsert_message(
               %{provider: "mattermost", provider_atom: :mattermost},
               %{
                 channel_id: outgoing.channel_id,
                 thread_id: outgoing.thread_id,
                 body: outgoing.body
               },
               connection
             )

    assert_received {:openai_request, "POST", "/api/v4/posts", "", streamed_body}
    assert Jason.decode!(streamed_body)["message"] == outgoing.body

    assert {:ok, receipt} =
             JidoChatBridge.send_reply(
               %{
                 outgoing
                 | metadata: %{
                     "message_id" => "streamed-post",
                     "on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}
                   }
               },
               connection
             )

    assert_received {:openai_request, "POST", "/api/v4/files", "", _upload}
    refute_received {:openai_request, "POST", "/api/v4/posts", "", _duplicate}
    assert_received {:openai_request, "PUT", "/api/v4/posts/streamed-post", "", final_body}
    assert Jason.decode!(final_body)["message"] == outgoing.body
    assert Jason.decode!(final_body)["file_ids"] == ["uploaded-file"]
    assert receipt.message_id == "streamed-post"
    assert receipt.confirmation == :confirmed

    assert [%{args: %{"post_id" => "streamed-post"}}] =
             Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)
  end

  test "recording failure never resends files and a repeated caller submission remains another send" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, _body ->
          case conn.request_path do
            "/api/v4/files" ->
              {201, %{"file_infos" => [%{"id" => "uploaded-file"}]}}

            "/api/v4/posts" ->
              {201,
               %{
                 "id" => "accepted-post",
                 "channel_id" => "private-room",
                 "file_ids" => ["uploaded-file"]
               }}
          end
        end,
        self()
      )

    start_supervised!(child)

    assert {:ok, config} =
             ChannelConfig.upsert_by_provider("mattermost", %{
               name: "File confirmation lifecycle",
               settings: %{"max_file_size" => 307_200},
               kind: "retrieval",
               enabled: true,
               url: String.trim_trailing(endpoint, "/v1"),
               max_file_size: 307_200,
               token: "synthetic-token"
             })

    outgoing = %{
      file_outgoing()
      | routing_context: %{channel_config_id: config.id},
        metadata: %{assistant_message_id: "persisted-answer"}
    }

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, delivery_node_router: Zaq.NodeRouterMock]
      )

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn confirmation ->
      send(self(), {:file_confirmation, confirmation})
      %{confirmation | response: {:error, :engine_unavailable}}
    end)

    for _submission <- 1..2 do
      assert {:ok,
              %{
                confirmation: :confirmed,
                message_id: "accepted-post",
                confirmation_recording: :unavailable
              }} =
               Api.handle_event(event, :deliver_outgoing, nil).response

      assert_received {:openai_request, "POST", "/api/v4/files", "", _upload}
      assert_received {:openai_request, "POST", "/api/v4/posts", "", post}
      assert Jason.decode!(post)["file_ids"] == ["uploaded-file"]
      assert_received {:file_confirmation, confirmation}
      assert confirmation.opts[:action] == :record_delivery_confirmation
      [original_attachment] = outgoing.delivery.attachments

      assert confirmation.request.outgoing.delivery.attachments == [
               %{original_attachment | content: nil}
             ]

      assert confirmation.request.outgoing.metadata == %{assistant_message_id: "persisted-answer"}
      assert confirmation.request.receipt.message_id == "accepted-post"
      refute_received {:openai_request, _, _, _, _}
    end

    verify!(Zaq.NodeRouterMock)
  end

  test "files update the existing post without duplicating the answer or appending success text" do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id", format: :markdown}}

    assert {:ok, %{action: :updated, message_id: "status-id"}} =
             JidoChatBridge.send_reply(outgoing, file_connection())

    assert_received {:file_upload, _, _, _}
    assert_received {:file_status, _, "status-id", "File caption", [file_ids: ["upload-id"]]}
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
  end

  test "configured limits constrain ZAQ plans for create and edit" do
    connection =
      batch_connection()
      |> Map.delete(:max_file_size)
      |> Map.put(:settings, %{"max_file_size" => 307_200})

    for metadata <- [%{}, %{message_id: "existing-post"}] do
      outgoing = %{batch_outgoing(10) | metadata: metadata}
      assert {:ok, receipt} = JidoChatBridge.send_reply(outgoing, connection)
      assert length(receipt.attachments) == 10
      refute Map.has_key?(receipt, :messages)
    end

    assert_received {:batch_post, _, ids, _}
    assert length(ids) == 10
    assert_received {:batch_edit, "existing-post", ids}
    assert length(ids) == 10
    refute_received {:batch_post, _, _, _}
  end

  test "ZAQ-owned splitting returns separate receipts for all fifteen files" do
    assert {:ok, %{confirmation: :confirmed, messages: [first, second]}} =
             JidoChatBridge.send_reply(batch_outgoing(15), batch_connection())

    assert length(first.attachments) == 10
    assert length(second.attachments) == 5
    assert first.message_id != second.message_id
    assert second.body == "Additional files (2/2)."
    assert_received {:batch_post, _, first_ids, _}
    assert length(first_ids) == 10
    assert_received {:batch_post, _, second_ids, _}
    assert length(second_ids) == 5
  end

  test "one message consumes exactly its two planned upload requests" do
    use_upload_requirements_adapter()
    outgoing = batch_outgoing(4)

    outgoing =
      update_in(outgoing.delivery.attachments, fn records ->
        Enum.map(records, &%{&1 | content: String.duplicate("x", 4096), size: 4096})
      end)

    connection = batch_connection()

    assert {:ok, files, []} =
             DeliveryAttachments.prepare(outgoing.delivery.attachments, %{},
               attachment_failure_policy: :continue
             )

    preparation_connection =
      Map.merge(connection, %{
        delivery_provider: :mattermost,
        delivery_channel_id: outgoing.channel_id
      })

    assert {:ok, candidate} =
             JidoChatBridge.prepare_upload_request(Enum.take(files, 2), preparation_connection)

    Process.put(:declared_upload_ceiling, candidate.encoded_bytes)
    assert {:ok, planned} = DeliveryAttachments.build_plan(outgoing, JidoChatBridge, connection)
    assert [%{attachment_refs: [0, 1, 2, 3]}] = planned.delivery.plan.groups
    assert Enum.count(planned.delivery.plan.steps, &(&1.operation == :upload)) == 2
    refute_received {:batch_upload, _}
    refute_received {:batch_post, _, _, _}

    assert {:ok, %{confirmation: :confirmed}} =
             DeliveryExecutor.execute(planned, JidoChatBridge, connection)

    assert_received {:batch_upload, first}
    assert_received {:batch_upload, second}
    assert Enum.map(first, & &1.filename) == ["file-1.txt", "file-2.txt"]
    assert Enum.map(second, & &1.filename) == ["file-3.txt", "file-4.txt"]
    assert_received {:batch_post, "File caption", ids, _}
    assert ids == Enum.map(1..4, &"file-#{&1}_txt")
    refute_received {:batch_upload, _}
    refute_received {:batch_post, _, _, _}
  end

  test "omitted leading upload groups edit the streamed post without a duplicate answer" do
    use_upload_requirements_adapter()
    Process.put(:declared_upload_ceiling, 1000)
    outgoing = batch_outgoing(11)
    [last] = Enum.take(outgoing.delivery.attachments, -1)

    oversized =
      Enum.map(
        Enum.take(outgoing.delivery.attachments, 10),
        &%{&1 | content: String.duplicate("x", 5000)}
      )

    connection =
      batch_connection()
      |> with_policy(:continue)

    for attachments <- [oversized ++ [last], oversized] do
      outgoing = %{
        outgoing
        | metadata: %{message_id: "streamed"},
          delivery: %{outgoing.delivery | attachments: attachments}
      }

      assert {:ok, planned} = DeliveryAttachments.build_plan(outgoing, JidoChatBridge, connection)
      [edit | _] = Enum.reject(planned.delivery.plan.steps, &(&1.operation == :upload))
      assert edit.operation == :edit
      assert edit.message_ref == {:existing, "streamed"}
      immutable_plan = planned.delivery.plan
      refute_received {:batch_upload, _}
      refute_received {:batch_post, _, _, _}

      assert {:ok, %{confirmation: :partial, messages: [receipt], failed_attachments: failures}} =
               DeliveryExecutor.execute(planned, JidoChatBridge, connection)

      assert planned.delivery.plan == immutable_plan
      assert receipt.message_id == "streamed"
      assert receipt.body == "File caption"
      assert Enum.map(failures, & &1.attachment_index) == Enum.to_list(0..9)

      if length(attachments) == 11 do
        assert receipt.delivered_attachment_indices == [10]
        assert_received {:batch_upload, [uploaded]}
        assert uploaded.filename == last.name
        assert uploaded.body == last.content
        assert_received {:batch_edit, "streamed", ["file-11_txt"]}
      else
        assert receipt.delivered_attachment_indices == []
        assert_received {:batch_edit, "streamed", nil}
      end

      refute_received {:batch_upload, _}
      refute_received {:batch_edit, _, _}
      refute_received {:batch_post, _, _, _}
    end
  end

  test "an absent adapter upload constraint normalizes without hiding unresolved or invalid values" do
    use_upload_requirements_adapter()
    connection = Map.delete(batch_connection(), :max_upload_request_size)
    outgoing = batch_outgoing(1)

    assert {:ok, requirements} = JidoChatBridge.transport_requirements(outgoing, connection)
    assert requirements.max_upload_request_bytes == :not_applicable

    for value <- [:unresolved, nil, 0, -1, "1000"] do
      Process.put(:declared_upload_ceiling, value)

      assert {:error, %{stage: :configuration}, :continue} =
               JidoChatBridge.transport_requirements(outgoing, connection)
    end

    Process.put(:declared_upload_ceiling, :not_applicable)

    for key <- [:max_file_size, :max_files_per_post] do
      Process.put(:omitted_required_limit, key)

      assert {:error, %{stage: :configuration}, :continue} =
               JidoChatBridge.transport_requirements(outgoing, connection)
    end

    refute_received {:batch_upload, _}
    refute_received {:batch_post, _, _, _}
  end

  test "the actual Mattermost adapter delivers without a ceiling even with obsolete upload settings" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]

          case conn.request_path do
            "/api/v4/files" ->
              names =
                Regex.scan(~r/filename="([^"]+)"/, body, capture: :all_but_first)
                |> List.flatten()

              assert length(names) in [5, 10]
              assert body =~ "contents"

              {201,
               %{
                 "file_infos" =>
                   Enum.map(names, fn name ->
                     %{"id" => String.replace(name, ".", "_"), "name" => name}
                   end)
               }}

            "/api/v4/posts" ->
              payload = Jason.decode!(body)
              {201, Map.put(payload, "id", "post-#{hd(payload["file_ids"])}")}
          end
        end,
        self()
      )

    start_supervised!(child)

    connection = %{
      url: String.trim_trailing(endpoint, "/v1"),
      token: "synthetic-token",
      max_file_size: 307_200
    }

    assert {:ok, sdk_limits} =
             ChatAdapter.file_requirements(
               Adapter,
               AdapterOptions.build(:mattermost, connection)
             )

    assert sdk_limits.max_files_per_post == 10
    assert Map.get(sdk_limits, :max_upload_request_size, :not_applicable) == :not_applicable

    for connection <- [
          connection,
          Map.put(connection, :max_upload_request_size, 1),
          Map.put(connection, :settings, %{"max_upload_request_size" => 1})
        ],
        policy <- [:abort, :continue] do
      outgoing = %{batch_outgoing(15) | thread_id: nil}
      connection = with_policy(connection, policy)
      assert {:ok, planned} = DeliveryAttachments.build_plan(outgoing, JidoChatBridge, connection)
      assert planned.delivery.plan.requirements.max_upload_request_bytes == :not_applicable

      assert Enum.map(planned.delivery.plan.groups, & &1.attachment_refs) == [
               Enum.to_list(0..9),
               Enum.to_list(10..14)
             ]

      assert Enum.count(planned.delivery.plan.steps, &(&1.operation == :upload)) == 2
      refute_received {:openai_request, _, _, _, _}

      assert {:ok, %{confirmation: :confirmed, messages: [root, reply], failed_attachments: []}} =
               DeliveryExecutor.execute(planned, JidoChatBridge, connection)

      assert root.message_id == "post-file-1_txt"
      assert reply.message_id == "post-file-11_txt"
      assert reply.thread_id == root.message_id
      assert reply.body == "Additional files (2/2)."
      assert root.delivered_attachment_indices == Enum.to_list(0..9)
      assert reply.delivered_attachment_indices == Enum.to_list(10..14)
      assert_received {:openai_request, "POST", "/api/v4/files", "", first_upload}
      assert_received {:openai_request, "POST", "/api/v4/files", "", second_upload}
      assert first_upload =~ "file-1.txt"
      assert second_upload =~ "file-11.txt"
      assert_received {:openai_request, "POST", "/api/v4/posts", "", root_body}
      assert_received {:openai_request, "POST", "/api/v4/posts", "", reply_body}
      assert Jason.decode!(root_body)["file_ids"] == Enum.map(1..10, &"file-#{&1}_txt")
      assert Jason.decode!(reply_body)["file_ids"] == Enum.map(11..15, &"file-#{&1}_txt")
      refute_received {:openai_request, _, _, _, _}
    end

    assert {:error, %{stage: :configuration}, :continue} =
             JidoChatBridge.transport_requirements(
               batch_outgoing(1),
               Map.delete(connection, :max_file_size)
             )
  end

  test "continue promotes a later confirmed root and invokes the reply callback once with the final ID" do
    Process.put(:fail_batch_post, 1)

    outgoing = %{
      batch_outgoing(25)
      | thread_id: nil,
        metadata: %{"on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}}
    }

    connection = with_policy(batch_connection(), :continue)

    assert {:ok,
            %{confirmation: :partial, messages: [root, reply], failed_attachments: failures} =
              report} =
             JidoChatBridge.send_reply(outgoing, connection)

    assert root.message_id == "post-2"
    assert root.body == "File caption"
    assert root.thread_id == nil
    assert reply.message_id == "post-3"
    assert reply.thread_id == "post-2"
    assert reply.body == "Additional files (3/3)."
    assert Enum.map(failures, & &1.attachment_index) == Enum.to_list(0..9)
    assert Enum.all?(failures, &(&1.delivery == :unconfirmed and &1.reason == :timeout))
    assert Enum.map(report.uploaded_only, & &1.attachment_index) == Enum.to_list(0..9)

    assert [%{args: %{"post_id" => "post-3"}}] =
             Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)
  end

  test "adapter partial delivery remains partial through the bridge" do
    Process.put(:fail_batch_post, 2)

    assert {:ok, %{confirmation: :partial, messages: [first], failed_attachments: failures}} =
             JidoChatBridge.send_reply(batch_outgoing(15), batch_connection())

    assert length(first.attachments) == 10
    assert length(failures) == 5
    assert Enum.all?(failures, &(&1.reason == :timeout))
  end

  test "provider upload rejection retains safe failure evidence and updates the original answer once" do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}

    assert {:ok, %{confirmation: :partial, failed_attachments: [failure]} = report} =
             deliver_outgoing(outgoing, file_connection("size_rejected"))

    assert failure.reason == {:http_error, 413}
    assert failure.stage == :upload
    assert report.uploaded_attachments == []
    refute inspect(report) =~ "private-provider-detail"

    assert_received {:file_upload, _, _, _}
    assert_received {:file_status, _, _, status, _}

    assert status == "File caption"

    refute status =~ "private-provider-detail"
    refute_received {:file_post, _, _, _}
    refute_received {:file_upload, _, _, _}
  end

  test "upload failure continues once while final attachment update failure stays unconfirmed" do
    for {failure, expected} <- [
          {"upload_failed", {:partial, :upload_failed}},
          {"post_failed", :unconfirmed}
        ] do
      result = assert_attachment_failure(failure, expected)
      refute inspect(result) =~ "private-provider-detail"
    end
  end

  test "upload timeout continues once while final attachment update timeout never sends again" do
    for {failure, expected} <- [
          {"upload_timeout", {:partial, :timeout}},
          {"post_timeout", :unconfirmed}
        ] do
      assert_attachment_failure(failure, expected)
    end
  end

  test "file delivery without a provider post ID is unconfirmed and does not invoke callbacks" do
    outgoing = %{
      file_outgoing()
      | metadata: %{
          "on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}
        }
    }

    assert {:error,
            %DeliveryError{
              reason: {:attachment_delivery_failed, %{step_outcomes: outcomes}},
              stage: :transport,
              delivery: :unconfirmed
            }} =
             JidoChatBridge.send_reply(outgoing, file_connection("missing_post_id"))

    assert Enum.any?(outcomes, &(&1[:reason] == :unconfirmed_delivery))

    assert Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker) == []

    assert_received {:file_upload, _, _, _}
    assert_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "confirmed delivery survives status errors, exceptions and exits with one upload and post" do
    for failure <- ["status_failed", "status_raised", "status_exit"] do
      outgoing = file_outgoing()

      capture_log(fn ->
        assert {:ok, %{confirmation: :confirmed, message_id: "final-post-id"}} =
                 JidoChatBridge.send_reply(outgoing, file_connection(failure))
      end)

      assert_received {:file_upload, _, _, _}
      assert_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "on_reply tracks the final post ID and callback exits cannot repeat the send" do
    for worker <- [FileReplyWorker, ExitingReplyWorker] do
      outgoing = %{
        file_outgoing()
        | metadata: %{"on_reply" => %{"module" => Atom.to_string(worker), "args" => %{}}}
      }

      capture_log(fn ->
        assert {:ok, %{confirmation: :confirmed, message_id: "final-post-id"}} =
                 JidoChatBridge.send_reply(outgoing, file_connection())
      end)

      if worker == FileReplyWorker do
        assert [%{args: %{"post_id" => "final-post-id"}}] =
                 Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)
      end

      assert_received {:file_upload, _, _, _}
      assert_received {:file_post, _, _, _}
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "denied preparation continues with the original answer while unsupported bodies remain rejected" do
    assert {:ok, handle} =
             CommunicationMedia.issue("mattermost", "private-file", %{
               "source_author_id" => "owner"
             })

    cases = [
      {%{file_outgoing() | delivery: %{file_outgoing().delivery | attachments: nil}},
       :invalid_attachments},
      {%{
         file_outgoing()
         | delivery: %{
             file_outgoing().delivery
             | attachments: [
                 %{
                   hd(file_outgoing().delivery.attachments)
                   | content: nil,
                     materialization_handle: handle
                 }
               ]
           }
       }, "Attachment preparation failed: :unauthorized_materialization_handle"},
      {%{file_outgoing() | body: 123}, :invalid_postable},
      {%{file_outgoing() | body: %{text: "hidden file", attachments: [%{path: "/private/file"}]}},
       :invalid_postable},
      {%{file_outgoing() | body: 123, delivery: %{file_outgoing().delivery | attachments: []}},
       :invalid_postable}
    ]

    for {outgoing, reason} <- cases do
      result = deliver_outgoing(outgoing, file_connection())

      if is_binary(reason) do
        assert {:ok,
                %{
                  confirmation: :partial,
                  failed_attachments: [%{stage: :preparation, reason: safe_reason}]
                }} = result

        assert safe_reason == "The attachment content could not be accessed."
      else
        assert {:error, %DeliveryError{reason: ^reason}} = result
      end

      refute_received {:file_upload, _, _, _}

      if is_binary(outgoing.body) do
        assert_received {:file_post, _, text, opts}

        expected =
          if reason == :invalid_attachments,
            do: "File caption\n\nThe attachment data is invalid.",
            else: "File caption"

        assert text == expected

        assert opts[:file_ids] == nil
      end

      refute_received {:file_post, _, _, _}
    end
  end

  test "unconfirmed delivery without a placeholder never reposts the answer or invokes callbacks" do
    outgoing = %{
      file_outgoing()
      | metadata: %{"on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}}
    }

    assert {:error,
            %DeliveryError{
              delivery: :unconfirmed,
              reason: {:attachment_delivery_failed, %{messages: []}}
            }} =
             deliver_outgoing(outgoing, file_connection("post_timeout"))

    assert_received {:file_upload, _, _, _}
    assert_received {:file_post, _, "File caption", _}
    assert Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker) == []
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
  end

  test "pipeline attachment mistakes reach delivery without losing the answer" do
    incoming = %Zaq.Engine.Messages.Incoming{
      content: "Send the file",
      provider: :mattermost,
      channel_id: "private-room"
    }

    connection = file_connection()

    for attachments <- [nil, [%{id: "not-a-record"}]] do
      outgoing =
        Outgoing.from_pipeline_result(incoming, %{
          answer: "Keep this answer",
          attachments: attachments
        })

      result = deliver_outgoing(outgoing, connection)

      if is_nil(attachments) do
        assert {:error, %DeliveryError{reason: :invalid_attachments}} = result
      else
        assert {:ok,
                %{
                  confirmation: :partial,
                  failed_attachments: [
                    %{stage: :preparation, reason: "The attachment data is invalid."}
                  ]
                }} = result
      end

      assert_received {:file_post, "private-room", text, opts}

      assert text ==
               if(is_nil(attachments),
                 do: "Keep this answer\n\nThe attachment data is invalid.",
                 else: "Keep this answer"
               )

      assert opts[:file_ids] == nil
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "legacy adapters without required file operations fail before acquisition or notices" do
    registry = Application.fetch_env!(:zaq, :channels)

    for scenario <- ["notice_failed", "notice_raised", "notice_exit"] do
      Application.put_env(
        :zaq,
        :channels,
        put_in(registry, [:mattermost, :adapter], FailingEditAdapter)
      )

      refute Jido.Chat.Adapter.capabilities(FailingEditAdapter)[:attachment_failure_policy] ==
               :native

      outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}

      capture_log(fn ->
        assert {:error,
                %DeliveryError{reason: :invalid_transport_requirements, stage: :configuration}} =
                 JidoChatBridge.send_reply(
                   outgoing,
                   with_policy(file_connection(scenario), :abort)
                 )
      end)

      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
    end
  end

  property "continuing after upload failure preserves the complete original answer, including empty text" do
    connection = file_connection("http_upload_failed")

    check all(body <- one_of([constant(""), string(:printable, max_length: 256)])) do
      outgoing = %{file_outgoing() | body: body, metadata: %{message_id: "status-id"}}

      assert {:ok,
              %{
                confirmation: :partial,
                failed_attachments: [%{reason: {:http_error, 400}, stage: :upload}],
                uploaded_attachments: []
              } = report} =
               deliver_outgoing(outgoing, connection)

      assert_received {:file_upload, _, _, _}
      assert_received {:file_status, _, "status-id", text, _}

      assert text == body
      assert [%{body: ^body, confirmation: :confirmed}] = report.messages
      refute inspect(report.failed_attachments) =~ "private-provider-detail"
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
    end
  end

  test "direct bridge failed uploads retain safe failure facts without a fallback publication" do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}

    assert {:error,
            %DeliveryError{
              reason: {:attachment_delivery_failed, report},
              stage: :transport,
              delivery: :not_sent
            }} =
             JidoChatBridge.send_reply(
               outgoing,
               with_policy(file_connection("size_rejected"), :abort)
             )

    assert [%{reason: {:http_error, 413}, stage: :upload, attachment_index: 0}] =
             report.failed_attachments

    assert report.messages == []

    assert_received {:file_upload, _, _, _}
    refute_received {:file_upload, _, _, _}
    refute_received {:file_status, _, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  defmodule BatchTransport do
    defdelegate prepare_upload(channel, files, opts),
      to: Zaq.Channels.JidoChatDeliveryTest.FileTransport

    def upload_prepared(prepared, opts),
      do: upload_files(prepared.channel_id, prepared.inputs, opts)

    def upload_files(_channel, files, _opts) do
      send(DeliveryTestOwner.pid(), {:batch_upload, files})

      {:ok,
       %{
         "file_infos" =>
           Enum.map(
             files,
             &%{
               "id" => String.replace(&1.filename, ".", "_"),
               "name" => &1.filename,
               "size" => byte_size(&1.body),
               "mime_type" => "text/plain"
             }
           )
       }}
    end

    def send_message(channel, text, opts) do
      count = :atomics.add_get(DeliveryTestOwner.get(:batch_post_counter), 1, 1)
      send(DeliveryTestOwner.pid(), {:batch_post, text, opts[:file_ids], opts})

      if DeliveryTestOwner.get(:fail_batch_post) == count,
        do: {:error, :timeout},
        else:
          {:ok,
           %{
             "id" => "post-#{count}",
             "channel_id" => channel,
             "user_id" => "bot",
             "file_ids" => opts[:file_ids]
           }}
    end

    def edit_message(channel, id, _text, opts) do
      send(DeliveryTestOwner.pid(), {:batch_edit, id, opts[:file_ids]})

      {:ok,
       %{"id" => id, "channel_id" => channel, "user_id" => "bot", "file_ids" => opts[:file_ids]}}
    end
  end

  defmodule UploadRequirementsAdapter do
    defdelegate capabilities(), to: Adapter
    defdelegate prepare_upload(channel, files, opts), to: Adapter
    defdelegate upload_prepared(prepared, opts), to: Adapter
    defdelegate send_message(channel, text, opts), to: Adapter
    defdelegate edit_message(channel, id, text, opts), to: Adapter

    def file_requirements(opts) do
      with {:ok, limits} <- Adapter.file_requirements(opts) do
        limits =
          case DeliveryTestOwner.get(:declared_upload_ceiling, :absent) do
            :absent -> Map.delete(limits, :max_upload_request_size)
            ceiling -> Map.put(limits, :max_upload_request_size, ceiling)
          end

        limits = Map.delete(limits, DeliveryTestOwner.get(:omitted_required_limit))
        {:ok, limits}
      end
    end
  end

  defp use_upload_requirements_adapter do
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      put_in(channels, [:mattermost, :adapter], UploadRequirementsAdapter)
    )
  end

  defp assert_attachment_failure(scenario, expected) do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}
    result = deliver_outgoing(outgoing, file_connection(scenario))
    assert_received {:file_upload, _, _, _}

    case expected do
      {:partial, reason} ->
        assert {:ok, %{confirmation: :partial, failed_attachments: [%{reason: ^reason}]}} = result
        assert_received {:file_status, _, "status-id", "File caption", []}

      :unconfirmed ->
        assert {:error,
                %DeliveryError{
                  delivery: :unconfirmed,
                  reason: {:attachment_delivery_failed, %{messages: []}}
                }} = result

        assert_received {:file_edit, _, "status-id", "File caption", [file_ids: ["upload-id"]]}
    end

    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
    refute_received {:file_edit, _, _, _, _}
    refute_received {:file_status, _, _, _, _}
    result
  end

  defp batch_outgoing(count) do
    %{
      file_outgoing()
      | routing_context: %{channel_config_id: 10},
        delivery: %{
          file_outgoing().delivery
          | attachments:
              for(
                i <- 1..count,
                do: %Record{
                  id: "record-#{i}",
                  kind: :file,
                  content: "contents",
                  name: "file-#{i}.txt",
                  mime_type: "text/plain"
                }
              )
        }
    }
  end

  defp with_policy(connection, policy),
    do:
      Map.update(
        connection,
        :settings,
        %{"send_on_file_failure" => policy == :continue},
        &Map.put(&1, "send_on_file_failure", policy == :continue)
      )

  defp batch_connection,
    do: %{
      url: "https://example.test",
      token: "test-token",
      max_file_size: 307_200,
      transport: BatchTransport,
      trusted_context: %TrustedContext{}
    }

  defp deliver_outgoing(outgoing, connection) do
    assert {:ok, config} =
             ChannelConfig.upsert_by_provider("mattermost", %{
               name: "Attachment failure notice",
               kind: "retrieval",
               enabled: true,
               url: connection.url,
               token: connection.token,
               settings: %{"max_file_size" => 307_200}
             })

    event =
      Event.new(%{outgoing | routing_context: %{channel_config_id: config.id}}, :channels,
        opts: [action: :deliver_outgoing, bridge_module: DeliveryBridge]
      )

    Api.handle_event(event, :deliver_outgoing, nil).response
  end

  defp file_outgoing(content \\ <<255, 0, 128>>) do
    %Outgoing{
      provider: :mattermost,
      channel_id: "private-room",
      thread_id: "root-post",
      body: "File caption",
      delivery: %Outgoing.Delivery{
        attachments: [
          %Record{
            id: "explicit-file",
            kind: :file,
            content: content,
            name: "résumé.pdf",
            mime_type: "application/pdf"
          }
        ]
      }
    }
  end

  defp file_connection(scenario \\ "success") do
    owner = self()

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]
          file_http_response(conn, body, scenario, owner)
        end,
        owner
      )

    start_supervised!(Supervisor.child_spec(child, id: make_ref()))

    %{
      url: String.trim_trailing(endpoint, "/v1") <> "/#{scenario}",
      max_file_size: 307_200,
      token: "synthetic-token",
      transport: FileTransport,
      trusted_context: %TrustedContext{}
    }
  end

  defp strict_upload_server do
    {_server, endpoint} =
      OpenAIStub.start!(
        fn
          %{method: "POST", request_path: "/api/v4/files"} = conn, body ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]

            if String.contains?(body, "filename=\"file-11.txt\"") do
              {413, %{"message" => "synthetic later-group upload rejection"}}
            else
              {201,
               %{
                 "file_infos" =>
                   Enum.map(1..10, &%{"id" => "uploaded-#{&1}", "name" => "file-#{&1}.txt"})
               }}
            end

          _conn, _body ->
            {500, %{"message" => "unexpected publication request"}}
        end,
        self()
      )

    String.trim_trailing(endpoint, "/v1")
  end

  defp file_http_response(%{method: "POST"} = conn, body, scenario, owner) do
    assert conn.request_path == "/#{scenario}/api/v4/files"
    assert body =~ "private-room"
    send(owner, {:file_upload, "private-room", %{multipart: body}, []})

    case scenario do
      scenario when scenario in ["upload_failed", "notice_failed"] ->
        {400, %{"message" => "private-provider-detail"}}

      "size_rejected" ->
        {413, %{"message" => "private-provider-detail"}}

      "upload_timeout" ->
        file_http_timeout()

      _ ->
        {201, %{"file_infos" => [%{"id" => "upload-id", "name" => "résumé.pdf"}]}}
    end
  end

  defp file_http_response(%{method: "PUT"} = conn, body, scenario, owner) do
    assert conn.request_path in [
             "/#{scenario}/api/v4/posts/status-id",
             "/#{scenario}/api/v4/posts/status-id/patch"
           ]

    payload = Jason.decode!(body)
    assert payload["id"] == "status-id"
    files = if payload["file_ids"], do: [file_ids: payload["file_ids"]], else: []
    failing_attachment? = files != [] and scenario in ["post_failed", "post_timeout"]
    event = if failing_attachment?, do: :file_edit, else: :file_status
    send(owner, {event, "private-room", payload["id"], payload["message"], files})

    case {scenario, failing_attachment?} do
      {"post_failed", true} -> {500, %{"message" => "private-provider-detail"}}
      {"post_timeout", true} -> file_http_timeout()
      {"notice_failed", _} -> {400, %{"message" => "synthetic edit rejection"}}
      _ -> {200, Map.put(payload, "channel_id", "private-room")}
    end
  end

  defp file_http_timeout do
    # Exercise Req's actual receive timeout without injecting a bridge transport.
    Process.sleep(16_000)
    {200, %{}}
  end

  test "unsupported providers retain the controlled delivery error without interning strings" do
    unknown = "unregistered-provider-#{System.unique_integer([:positive])}"

    for provider <- [unknown, nil, :unsupported] do
      outgoing = %Outgoing{provider: provider, channel_id: "private-room", body: "Harmless"}

      assert {:error, %DeliveryError{reason: {:unsupported_provider, ^provider}}} =
               JidoChatBridge.send_reply(outgoing, %{url: "http://unused.invalid", token: "test"})
    end

    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(unknown, :utf8) end
  end

  property "registered provider strings and atoms pass the bridge's real Thread constructor", %{
    registry: registry
  } do
    Application.put_env(:zaq, :channels, registry)
    # Read the production registry, rather than maintaining another provider enumeration.
    providers = for {provider, %{adapter: _}} <- registry, do: provider

    check all(provider <- member_of(providers), string? <- boolean()) do
      input = if string?, do: Atom.to_string(provider), else: provider
      assert {:ok, _adapter} = JidoChatBridge.adapter_for(input)
      assert JidoChatBridge.provider_to_atom(input) === provider

      incoming = %Jido.Chat.Incoming{
        external_room_id: "private-room",
        channel_meta: %Jido.Chat.ChannelMeta{adapter_name: input},
        author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
      }

      assert :ok =
               JidoChatBridge.handle_from_listener(
                 %{provider: input, url: "http://unused.invalid", token: "test"},
                 incoming,
                 []
               )
    end
  end

  test "listener config string passes the real Thread constructor before ignoring the bot's message" do
    incoming = %Jido.Chat.Incoming{
      external_room_id: "private-room",
      author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
    }

    assert :ok =
             JidoChatBridge.handle_from_listener(
               %{provider: "mattermost", url: "http://unused.invalid", token: "test"},
               incoming,
               []
             )
  end

  test "authentication crosses Jido Exec, Engine, Notifications, real Thread and Mattermost HTTP" do
    connection = http_server()
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        event =
          Events.build_and_dispatch_invoke_event(
            %{op: :request_challenge, email: person.email, ip: {127, 0, 3, 41}},
            :people_auth,
            event_opts: [confidential: true]
          )

        assert {:ok, descriptor} = event.response

        assert Enum.sort(Map.keys(descriptor)) == [
                 :challenge_id,
                 :expires_at,
                 :resend_available_at
               ]

        assert {:ok, ^descriptor} = PeopleAuth.challenge_status(descriptor.challenge_id)
        assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
        payload = Jason.decode!(body)
        assert payload["channel_id"] == "private-room"
        refute Map.has_key?(payload, "root_id")
        [_, code] = Regex.run(~r/\*\*([0-9]{4}-[0-9]{4})\*\*/, payload["message"])

        assert payload["message"] ==
                 "Your ZAQ sign-in code is\n\n**#{code}**\n\nDo not share this code.\n\n*Input this code in the current Sign-in page*"

        send(self(), {:delivered_code, code})

        row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
        assert row.status == "sent"
        assert row.payload["body"] == payload["message"]

        assert {:ok, %{token: token}} =
                 PeopleAuthGateway.dispatch(
                   %{op: :verify, challenge_id: descriptor.challenge_id, code: code},
                   []
                 )

        assert {:ok, %{person: authenticated}} =
                 PeopleAuthGateway.dispatch(%{op: :authenticate, token: token}, [])

        assert authenticated.id == person.id
      end)

    assert_received {:delivered_code, code}
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  test "real HTTP delivery failure invalidates its exact challenge and stores a failed notification" do
    connection = http_server(403)
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} =
                 PeopleAuthGateway.request_challenge(person.email, {127, 0, 3, 42})
      end)

    assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, Jason.decode!(body)["message"])
    challenge = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert challenge.invalidated_at
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(challenge.id)
    row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
    assert row.status == "failed"
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  defp http_server(status \\ 201) do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]
          payload = Jason.decode!(body)
          {status, Map.merge(payload, %{"id" => payload["id"] || "sent-post", "create_at" => 0})}
        end,
        self()
      )

    start_supervised!(child)

    %{
      url: String.trim_trailing(endpoint, "/v1"),
      max_file_size: 307_200,
      token: "synthetic-token"
    }
  end

  defp authentication_person(connection) do
    {:ok, config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Synthetic delivery",
        kind: "retrieval",
        enabled: true,
        url: connection.url,
        token: connection.token,
        settings: %{"max_file_size" => 307_200}
      })

    {:ok, person} =
      People.create_person(%{full_name: "Delivery", email: "delivery@example.test"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_config_id: config.id,
        channel_identifier: "private-room",
        weight: 0
      })

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    person
  end
end
