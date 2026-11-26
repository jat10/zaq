defmodule Zaq.Channels.Delivery.PreparationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Channels.Delivery.{Attachments, Preparation}
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Channels.TransportRequirements
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Materialization

  setup :verify_on_exit!

  test "binary acquisition is explicit, transient and measures actual bytes" do
    record = %{file() | content: <<0, 255, 1>>, size: 1}
    assert {:ok, attachment} = Preparation.acquire(record, requirements())

    assert attachment == %{
             content: <<0, 255, 1>>,
             size: 3,
             name: "file.txt",
             mime_type: "text/plain"
           }

    assert record.size == 1
    assert record.content == <<0, 255, 1>>
  end

  property "standard base64 decoding preserves arbitrary bytes with optional padding and whitespace" do
    check all(bytes <- binary(max_length: 200)) do
      encoded = bytes |> Base.encode64() |> String.trim_trailing("=")

      record = %{
        file()
        | content: "\n " <> encoded <> "\t",
          attributes: %{"encoding" => "base64"}
      }

      assert {:ok, attachment} = Preparation.acquire(record, requirements())
      assert attachment.content == bytes
      assert attachment.size == byte_size(bytes)
    end
  end

  test "UTF-8 preserves Unicode and base64-looking text for both encoding key forms" do
    for content <- ["hello", "héllo 世界", "aGVsbG8="],
        attributes <- [%{"encoding" => "utf-8"}, %{encoding: "utf-8"}] do
      record = %{file() | content: content, attributes: attributes}
      assert {:ok, acquired} = Preparation.acquire(record, requirements())
      assert acquired.content == content
      assert acquired.size == byte_size(content)

      assert {:error, :file_too_large} =
               Preparation.acquire(
                 record,
                 requirements(max_attachment_bytes: byte_size(content) - 1)
               )
    end
  end

  test "absent and binary encoding preserve bytes without guessing base64" do
    for attributes <- [%{}, %{"encoding" => "binary"}, %{encoding: "binary"}] do
      assert {:ok, %{content: "aGVsbG8="}} =
               Preparation.acquire(
                 %{file() | content: "aGVsbG8=", attributes: attributes},
                 requirements()
               )
    end
  end

  test "invalid encodings, content, handle and unavailable sources fail explicitly" do
    for {record, reason} <- [
          {%{file() | content: "%%%", attributes: %{"encoding" => "base64"}},
           :invalid_attachment_base64},
          {%{file() | content: "_-8=", attributes: %{"encoding" => "base64"}},
           :invalid_attachment_base64},
          {%{file() | content: "hello", attributes: %{"encoding" => "gzip"}},
           :invalid_attachment_encoding},
          {%{file() | content: %{}}, :invalid_attachment_content},
          {%{file() | content: nil}, :attachment_content_unavailable},
          {nil, :invalid_attachment}
        ] do
      assert {:error, ^reason} = Preparation.acquire(record, requirements())
    end

    assert {:error, reason} =
             Preparation.acquire(
               %{file() | content: nil, materialization_handle: "forged"},
               requirements()
             )

    assert reason =~ "invalid_materialization_handle"
  end

  test "invalid metadata is checked before acquisition" do
    for record <- [
          %{file() | name: "../file"},
          %{file() | name: <<255>>},
          %{file() | name: ".."},
          %{file() | name: ""},
          %{file() | name: 1},
          %{file() | mime_type: "text/plain;bad"},
          %{file() | mime_type: 1}
        ] do
      assert {:error, :invalid_attachment_metadata} =
               Preparation.acquire(
                 %{record | content: nil, materialization_handle: "forged"},
                 requirements()
               )
    end
  end

  test "actual size drift enforces known single-file and group lower bounds" do
    record = %{file() | content: "four", size: 1}

    for {field, reason} <- [
          max_attachment_bytes: :file_too_large,
          max_attachment_bytes_per_message: :message_too_large,
          max_encoded_message_bytes: :message_too_large,
          max_upload_request_bytes: :upload_request_too_large
        ] do
      mode =
        if field == :max_encoded_message_bytes,
          do: :send_with_attachments,
          else: :upload_then_publish

      assert {:error, ^reason} =
               Preparation.acquire(record, requirements([{field, 3}, {:transfer_mode, mode}]))
    end

    for limit <- [:unresolved, :not_applicable, 4] do
      assert {:ok, %{size: 4}} =
               Preparation.acquire(record, requirements(max_attachment_bytes: limit))
    end
  end

  test "actual fixed-group validation rejects growth without changing plan or sources" do
    records = [%{file() | content: "four", size: 1}, %{file() | content: "five!", size: 1}]

    outgoing = %Outgoing{
      body: "answer",
      channel_id: "room",
      provider: :test,
      attachments: records
    }

    requirements = requirements(max_attachment_bytes_per_message: 8)
    assert {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    assert [%{attachment_refs: [0, 1]}] = plan.groups

    acquired =
      Enum.map(records, fn record ->
        assert {:ok, attachment} = Preparation.acquire(record, requirements)
        attachment
      end)

    assert {:error, :message_too_large} = Attachments.validate_group(acquired, requirements)
    assert [%{attachment_refs: [0, 1]}] = plan.groups
    assert outgoing.attachments == records
  end

  test "explicit acquisition redeems a real signed communication handle with trusted identity" do
    record = lazy_file()
    actor = %{id: "author-1"}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :channels
      assert event.opts[:action] == :materialize_record
      assert event.opts[:materialization_verified]
      refute event.opts[:skip_permissions]
      assert event.actor == actor
      assert event.request["reference"] == "file-1"

      %{
        event
        | response:
            {:ok,
             %Record{
               id: "file-1",
               kind: :file,
               content: "aGVsbG8=",
               attributes: %{"encoding" => "base64"}
             }}
      }
    end)

    assert {:ok, attachment} =
             Preparation.acquire(record, requirements(), %{
               actor: actor,
               node_router: Zaq.NodeRouterMock,
               token: "excluded",
               event_opts: [skip_permissions: true]
             })

    assert attachment.content == "hello"
    assert attachment.name == record.name
    assert record.content == nil
    assert is_binary(record.materialization_handle)
  end

  test "fixed upload batches reject actual aggregate growth without regrouping" do
    attachments = [%{size: 3}, %{size: 3}]

    assert {:error, :upload_request_too_large} =
             Attachments.validate_upload_group(
               attachments,
               requirements(max_upload_request_bytes: 5)
             )

    for ceiling <- [:unresolved, :not_applicable, 6] do
      assert :ok =
               Attachments.validate_upload_group(
                 attachments,
                 requirements(max_upload_request_bytes: ceiling)
               )
    end
  end

  test "nil identity, incoming claims and nonliteral bypass never imply elevated access" do
    for context <- [
          %{},
          %{actor: nil},
          %{actor: %{person: nil}},
          %{incoming: %{author_id: "author-1"}},
          %{actor: %{id: "other"}},
          %{skip_permissions: "true"},
          %{event_opts: [skip_permissions: true]}
        ] do
      assert {:error, reason} =
               Preparation.acquire(
                 lazy_file(),
                 requirements(),
                 Map.put(context, :node_router, Zaq.NodeRouterMock)
               )

      assert reason =~ "unauthorized_materialization_handle"
    end
  end

  test "only explicit trusted bypass is projected to existing materialization security" do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == nil
      assert event.opts[:skip_permissions] == true
      %{event | response: {:ok, %{record: %{file() | content: "bytes"}}}}
    end)

    assert {:ok, %{content: "bytes"}} =
             Preparation.acquire(lazy_file(), requirements(), %{
               skip_permissions: true,
               node_router: Zaq.NodeRouterMock
             })
  end

  test "canonical authorization denial cannot fall back to author or explicit bypass" do
    source =
      CommunicationMedia.source_metadata("mattermost", "file-1", %{
        "source_author_id" => "author-1",
        "channel_config_id" => 3,
        "source_channel_id" => "room",
        "source_message_id" => "message"
      })

    descriptor =
      Record.attachment_metadata(%Record{
        id: "file-1",
        kind: :file,
        attributes: %{"materialization_source" => source}
      })

    assert {:ok, record} =
             CommunicationMedia.hydrate(
               %{
                 descriptor: descriptor,
                 transcript_id: Ecto.UUID.generate(),
                 message_id: Ecto.UUID.generate()
               },
               %{}
             )

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :conversation
      assert event.request.action == :canonical_message
      %{event | response: {:error, :unauthorized}}
    end)

    assert {:error, reason} =
             Preparation.acquire(record, requirements(), %{
               actor: %{id: "author-1"},
               skip_permissions: true,
               node_router: Zaq.NodeRouterMock
             })

    assert reason =~ "unauthorized_materialization_handle"
  end

  test "materialized metadata and content are validated again" do
    for returned <- [
          %{file() | name: "bad\r\nname", content: "bytes"},
          %{file() | kind: :folder, content: "bytes"},
          %{file() | content: []}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{event | response: {:ok, %{record: returned}}}
      end)

      assert {:error, _} =
               Preparation.acquire(lazy_file(), requirements(), %{
                 actor: %{id: "author-1"},
                 node_router: Zaq.NodeRouterMock
               })
    end
  end

  test "missing display metadata receives safe defaults" do
    assert {:ok, attachment} =
             Preparation.acquire(
               %{file() | name: nil, mime_type: nil, content: ""},
               requirements()
             )

    assert attachment == %{
             content: "",
             size: 0,
             name: "attachment",
             mime_type: "application/octet-stream"
           }
  end

  test "invalid requirements and context cannot acquire content" do
    assert {:error, :invalid_requirements} = Preparation.acquire(lazy_file(), nil)

    assert {:error, :invalid_trusted_context} =
             Preparation.acquire(lazy_file(), requirements(), nil)
  end

  for failure <- [:raise, :throw, :exit] do
    test "acquisition #{failure} returns a bounded error without provider details" do
      expect(Zaq.NodeRouterMock, :dispatch, fn _ ->
        case unquote(failure) do
          :raise -> raise "PRIVATE_DETAILS"
          :throw -> throw("PRIVATE_DETAILS")
          :exit -> exit("PRIVATE_DETAILS")
        end
      end)

      assert {:error, reason} =
               Preparation.acquire(lazy_file(), requirements(), %{
                 actor: %{id: "author-1"},
                 node_router: Zaq.NodeRouterMock
               })

      assert reason in [:attachment_preparation_exception, :attachment_preparation_exit]
    end
  end

  defp lazy_file do
    assert {:ok, handle} =
             Materialization.issue("communication_media", %{
               "provider" => "mattermost",
               "reference" => "file-1",
               "source_author_id" => "author-1"
             })

    %{file() | content: nil, materialization_handle: handle}
  end

  defp file, do: %Record{id: "file-1", kind: :file, name: "file.txt", mime_type: "text/plain"}

  defp requirements(overrides \\ []),
    do:
      struct!(
        TransportRequirements,
        Keyword.merge(
          [transfer_mode: :upload_then_publish, max_attachments_per_message: 3],
          overrides
        )
      )
end
