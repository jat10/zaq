defmodule Zaq.Channels.Delivery.AttachmentsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.Delivery.{Attachments, Executor}
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Events.TrustedContext
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.Api, as: StorageApi
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.Storage.StorageEntry

  setup :verify_on_exit!

  test "file requirements distinguish unresolved limits from inapplicable constraints" do
    alias Zaq.Channels.TransportRequirements

    requirements = %TransportRequirements{
      transfer_mode: :send_with_attachments,
      max_attachments_per_message: 5,
      max_attachment_bytes: :not_applicable,
      max_attachment_bytes_per_message: :not_applicable,
      max_encoded_message_bytes: 1_000_000,
      max_upload_request_bytes: :not_applicable
    }

    assert :ok = TransportRequirements.validate(requirements)

    for value <- [nil, :unresolved, 0, -1, "1000"] do
      assert {:error, %Zaq.Channels.Delivery.Error{stage: :configuration, delivery: :not_sent}} =
               TransportRequirements.validate(%{requirements | max_encoded_message_bytes: value})
    end

    assert {:error, _} = TransportRequirements.validate(%{requirements | transfer_mode: :unknown})

    assert :ok =
             TransportRequirements.validate(%{requirements | transfer_mode: :upload_then_publish})
  end

  property "upload constraints accept explicit non-applicability but reject unresolved limits" do
    alias Zaq.Channels.TransportRequirements

    check all(ceiling <- one_of([positive_integer(), constant(:not_applicable)])) do
      requirements = %TransportRequirements{
        transfer_mode: :upload_then_publish,
        max_attachments_per_message: 10,
        max_attachment_bytes: 307_200,
        max_attachment_bytes_per_message: :not_applicable,
        max_encoded_message_bytes: :not_applicable,
        max_upload_request_bytes: ceiling
      }

      assert :ok = TransportRequirements.validate(requirements)

      for value <- [nil, :unresolved, 0, -1, "1000"] do
        assert {:error, %{stage: :configuration}} =
                 TransportRequirements.validate(%{requirements | max_upload_request_bytes: value})
      end
    end
  end

  test "email file requirements use only the selected connector's explicit limits" do
    outgoing = %Outgoing{
      body: "Answer",
      provider: :"email:smtp",
      channel_id: "to@example.test"
    }

    connection = %{
      smtp_settings: %{
        "max_encoded_message_bytes" => 1_234_567,
        "max_attachments_per_message" => 3
      }
    }

    assert {:ok, requirements} = EmailBridge.transport_requirements(outgoing, connection)
    assert requirements.max_encoded_message_bytes == 1_234_567
    assert requirements.max_attachments_per_message == 3
    assert requirements.transfer_mode == :send_with_attachments

    assert {:error, %{stage: :configuration}, :continue} =
             EmailBridge.transport_requirements(outgoing, %{smtp_settings: %{}})
  end

  defmodule StorageConfig do
    def get(:zaq, Zaq.Storage, _default, opts), do: Keyword.fetch!(opts, :storage_config)
  end

  defmodule PreparationBridge do
    def transport_requirements(_outgoing, _connection) do
      {:ok,
       %Zaq.Channels.TransportRequirements{
         failure_policy: :abort,
         transfer_mode: :send_with_attachments,
         max_attachments_per_message: 100,
         max_attachment_bytes: :not_applicable,
         max_attachment_bytes_per_message: :not_applicable,
         max_encoded_message_bytes: :not_applicable,
         max_upload_request_bytes: :not_applicable
       }}
    end

    def execute_delivery_step(_step, _inputs, %{outcome: :raise}),
      do: raise("consumer failed")

    def execute_delivery_step(_step, _inputs, _connection),
      do:
        {:error,
         %Zaq.Channels.Delivery.Error{
           reason: :transport_unavailable,
           message: "Transport unavailable.",
           stage: :transport,
           delivery: :unconfirmed
         }, %{}}
  end

  property "raw and declared base64 normalization preserve every byte and attachment order" do
    check all(bytes <- binary(max_length: 2_048)) do
      records = [file(bytes), file(Base.encode64(bytes), %{"encoding" => "base64"})]

      assert {:ok, %{attachments: %{0 => raw, 1 => decoded}}} = plan_and_prepare(records, %{})
      assert Map.delete(raw, :attachment_index) == Map.delete(decoded, :attachment_index)
      assert raw.attachment_index == 0
      assert decoded.attachment_index == 1
      assert raw.content == bytes
      assert raw.size == byte_size(bytes)
    end
  end

  property "standard base64 with whitespace and optional padding preserves every byte" do
    check all(bytes <- binary(max_length: 2_048)) do
      encoded =
        bytes
        |> Base.encode64(padding: false)
        |> String.graphemes()
        |> Enum.chunk_every(7)
        |> Enum.map_join("\r\n", &Enum.join/1)

      record = file(" \t" <> encoded <> "\n", %{"encoding" => "base64"})

      assert {:ok, %{attachments: %{0 => prepared}}} = plan_and_prepare([record], %{})
      assert prepared.content == bytes
      assert prepared.size == byte_size(bytes)
    end
  end

  test "malformed and URL-safe base64 retain the attachment error contract" do
    for encoded <- ["%%%", "a", "-_8="] do
      assert {:error, %{reason: :invalid_attachment_base64}} =
               plan_and_prepare([file(encoded, %{"encoding" => "base64"})], %{})
    end
  end

  test "existing bytes preserve non-UTF8 content and expose only transport fields" do
    bytes = <<0, 255, 254, 128, 10>>

    record = %{
      file(bytes, %{"encoding" => "binary", "token" => "private"})
      | name: "résumé.pdf",
        mime_type: "application/pdf",
        path: "/private/original.pdf",
        url: "https://private.example/file",
        raw: %{credentials: "private"},
        size: 999,
        materialization_handle: "unused"
    }

    assert {:ok, %{attachments: %{0 => prepared}}} = plan_and_prepare([record], %{})

    assert prepared == %{
             attachment_index: 0,
             content: bytes,
             name: "résumé.pdf",
             mime_type: "application/pdf",
             size: 5
           }
  end

  test "missing display metadata receives safe defaults without guessing an encoding" do
    record = %{file("aGVsbG8=") | name: nil, mime_type: nil}

    assert {:ok,
            %{
              attachments: %{
                0 => %{
                  content: "aGVsbG8=",
                  name: "attachment",
                  mime_type: "application/octet-stream"
                }
              }
            }} = plan_and_prepare([record], %{})
  end

  test "invalid collections, Records, content, encoding and header metadata return preparation errors" do
    invalid = [
      nil,
      %{},
      [%{id: "not-a-record", kind: :file, content: "bytes"}],
      [%{file("bytes") | kind: :folder}],
      [%{file("bytes") | id: nil}],
      [file([1, 2, 3])],
      [file(%{bytes: "bytes"})],
      [file("%%%", %{"encoding" => "base64"})],
      [file("abc", %{"encoding" => "gzip"})],
      [%{file("bytes") | attributes: []}],
      [%{file("bytes") | name: "bad\r\nBcc: hidden"}],
      [%{file("bytes") | name: "../private.pdf"}],
      [%{file("bytes") | name: "bad\\private.pdf"}],
      [%{file("bytes") | name: <<255>>}],
      [%{file("bytes") | mime_type: "application/pdf\r\nX-Secret: value"}],
      [%{file("bytes") | mime_type: 42}]
    ]

    for records <- invalid do
      assert {:error, _reason} =
               plan_and_prepare(records, %{})
    end
  end

  test "a path alone is never read as attachment content" do
    fixture = storage_fixture()
    record = %{fixture.record | materialization_handle: nil, path: fixture.path}

    assert {:error, %{reason: :attachment_content_unavailable}} =
             plan_and_prepare([record], %{})

    assert File.read!(fixture.path) == fixture.bytes
  end

  test "lazy disk files use real Storage authorization and materialize once during preparation" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:ok, %{attachments: %{0 => prepared}}} =
             plan_and_prepare(
               [fixture.record],
               %{
                 actor: fixture.actor,
                 token: "destination-secret",
                 incoming: %{author_id: "fake"}
               },
               node_router: Zaq.NodeRouterMock
             )

    assert prepared.content == fixture.bytes
    assert prepared.name == "report.bin"
    assert prepared.mime_type == "application/octet-stream"
    assert prepared.size == byte_size(fixture.bytes)
    assert File.read!(fixture.path) == fixture.bytes
  end

  test "missing, forged and denied identities cannot read a signed disk source" do
    fixture = storage_fixture()

    for context <- [
          %{},
          %{person_id: fixture.actor.person_id},
          %{incoming: %{person: %{id: fixture.actor.person_id}}, credentials: "fake"},
          %{actor: %{person_id: nil}},
          %{actor: %{person_id: person_fixture().id}}
        ] do
      expect_storage(fixture.opts)

      assert {:error, %{reason: "Attachment preparation failed: :unauthorized"}} =
               plan_and_prepare(
                 [fixture.record],
                 context,
                 node_router: Zaq.NodeRouterMock
               )
    end
  end

  test "current source grant revocation denies a previously usable handle" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:ok, %{attachments: %{0 => _}}} =
             plan_and_prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )

    assert :ok = Permissions.revoke(fixture.resource, fixture.permission)
    expect_storage(fixture.opts)

    assert {:error, %{reason: "Attachment preparation failed: :unauthorized"}} =
             plan_and_prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "removed source files fail without returning partial prepared files" do
    fixture = storage_fixture()
    File.rm!(fixture.path)
    expect_storage(fixture.opts)

    assert {:error, _} =
             plan_and_prepare(
               [file("first"), fixture.record],
               %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "communication handles cannot use incoming author or request bypass to forge identity" do
    assert {:ok, handle} =
             CommunicationMedia.issue("mattermost", "source-file", %{
               "source_author_id" => "owner"
             })

    for context <- [
          %{incoming: %{author_id: "owner"}},
          %{actor: %{id: "other"}, request: %{skip_permissions: true, actor: %{id: "owner"}}},
          %{actor: nil, skip_permissions: "true"}
        ] do
      assert {:error,
              %{reason: "Attachment preparation failed: :unauthorized_materialization_handle"}} =
               plan_and_prepare(
                 [%{file(nil) | materialization_handle: handle}],
                 context
               )
    end
  end

  test "source failures and malformed source payloads return preparation errors" do
    assert {:ok, handle} = DiskDocument.issue("source-file")
    record = %{file(nil) | materialization_handle: handle}

    for response <- [
          {:error, :source_unavailable},
          {:ok, %{content: "%%%", encoding: "base64"}},
          {:ok, %{content: %{unexpected: "map"}}}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: response} end)

      assert {:error, _} =
               plan_and_prepare(
                 [record],
                 %TrustedContext{},
                 node_router: Zaq.NodeRouterMock
               )
    end
  end

  test "materialized representation metadata takes precedence over original source metadata" do
    assert {:ok, handle} = DiskDocument.issue("source-file")

    record = %{
      file(nil)
      | name: "source.doc",
        mime_type: "application/msword",
        materialization_handle: handle
    }

    bytes = <<255, 0, 128>>

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{person_id: 123}
      refute Keyword.has_key?(event.opts, :credentials)

      %{
        event
        | response:
            {:ok,
             %{
               record: %Record{
                 id: "source-file",
                 kind: :file,
                 name: "source.pdf",
                 mime_type: "application/pdf",
                 content: Base.encode64(bytes),
                 attributes: %{"encoding" => "base64"}
               }
             }}
      }
    end)

    assert {:ok,
            %{
              attachments: %{
                0 => %{name: "source.pdf", mime_type: "application/pdf", content: ^bytes, size: 3}
              }
            }} =
             plan_and_prepare(
               [record],
               %{actor: %{person_id: 123}, credentials: "destination-secret"},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "only a literal trusted bypass allows a nil actor to materialize a private file" do
    fixture = storage_fixture()

    for bypass <- ["true", true] do
      expect_storage(fixture.opts)

      result =
        plan_and_prepare(
          [fixture.record],
          %{actor: nil, skip_permissions: bypass},
          node_router: Zaq.NodeRouterMock
        )

      if bypass == true do
        assert {:ok, %{attachments: %{0 => %{content: content}}}} = result
        assert content == fixture.bytes
      else
        assert {:error, %{reason: "Attachment preparation failed: :unauthorized"}} = result
      end
    end
  end

  test "invalid handles fail through the registered materialization boundary" do
    for handle <- ["forged-handle", ""] do
      assert {:error, _} =
               plan_and_prepare(
                 [%{file(nil) | materialization_handle: handle}],
                 %{}
               )
    end
  end

  test "transport errors and exceptions preserve original files during execution" do
    fixture = storage_fixture()

    for outcome <- [:error, :raise] do
      expect_storage(fixture.opts)

      connection = %{
        trusted_context: %{actor: fixture.actor},
        node_router: Zaq.NodeRouterMock,
        outcome: outcome
      }

      assert {:ok, planned} =
               Attachments.build_plan(outgoing([fixture.record]), PreparationBridge, connection)

      assert {:error, %{delivery: :unconfirmed}} =
               Executor.execute(planned, PreparationBridge, connection)

      assert File.read!(fixture.path) == fixture.bytes
    end
  end

  defp plan_and_prepare(records, context, opts \\ []) do
    connection = Map.put(Map.new(opts), :trusted_context, context)

    with {:ok, planned} <-
           Attachments.build_plan(outgoing(records), PreparationBridge, connection) do
      Attachments.prepare_execution(planned, PreparationBridge, connection)
    end
  end

  defp outgoing(records),
    do: %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: "Answer",
      delivery: %Outgoing.Delivery{attachments: records}
    }

  defp file(content, attributes \\ %{}) do
    %Record{
      id: "explicit-file",
      kind: :file,
      name: "report.bin",
      mime_type: "application/octet-stream",
      content: content,
      attributes: attributes
    }
  end

  defp storage_fixture do
    root = Path.join(System.tmp_dir!(), "delivery_files_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "report.bin")
    bytes = <<0, 255, 254, 128, 10>>
    File.write!(path, bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [config: StorageConfig, storage_config: [base_path: root, volumes: %{"files" => root}]]
    assert {:ok, entry} = Storage.file_info("files", "report.bin", opts)
    resource = %StorageEntry{id: entry.id}
    actor = %{person_id: person_fixture().id}
    assert {:ok, permission} = Permissions.grant(resource, %{person_id: actor.person_id})
    assert {:ok, handle} = DiskDocument.issue(entry.id)

    %{
      path: path,
      bytes: bytes,
      actor: actor,
      resource: resource,
      permission: permission,
      opts: opts,
      record: %{file(nil) | materialization_handle: handle}
    }
  end

  defp expect_storage(opts) do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :storage
      assert event.opts[:action] == :materialize_document
      refute Map.has_key?(event.request, :credentials)
      refute Keyword.has_key?(event.opts, :token)
      event = %{event | opts: Keyword.merge(event.opts, opts)}
      StorageApi.handle_event(event, :materialize_document, nil)
    end)
  end

  defp person_fixture do
    unique = System.unique_integer([:positive])
    {:ok, person} = People.create_person(%{full_name: "Delivery Person #{unique}"})
    person
  end
end
