defmodule Zaq.Channels.JidoChatBridge.FileDeliveryTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Delivery.{Attachments, Executor, Preparation, Result}
  alias Zaq.Channels.{JidoChatBridge, TransportRequirements}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Test.FileDeliveryAdapter

  test "real bridge, resolver, executor and SDK upload once and publish only provider references" do
    connection = connection()
    outgoing = outgoing()
    assert {:ok, snapshot} = JidoChatBridge.capability_snapshot(connection)
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    assert requirements.supports_attachment_edits
    assert {:ok, plan} = Attachments.build_plan(outgoing, requirements)
    assert {:ok, result} = Executor.execute(outgoing, plan, JidoChatBridge, connection)
    assert [%{message_id: id, confirmation: :confirmed}] = Result.confirmed_receipts(result)
    assert is_binary(id)
    assert_receive {:adapter_upload, %{files: [%{data: <<0, 255>>}]}}
    assert_receive {:adapter_send, "room", "answer", opts}
    assert opts[:uploaded_files] == [%{id: "uploaded-0"}]
    refute Keyword.has_key?(opts, :files)
    refute_received {:adapter_upload, _}
    refute_received {:adapter_send, _, _, _}
  end

  test "an explicitly supported attachment edit targets the streamed message exactly once" do
    connection = connection()
    assert {:ok, snapshot} = JidoChatBridge.capability_snapshot(connection)
    assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
    assert {:ok, plan} = Attachments.build_plan(outgoing(), requirements, "streamed")
    assert {:ok, result} = Executor.execute(outgoing(), plan, JidoChatBridge, connection)
    assert [%{message_id: "streamed", action: :updated}] = Result.confirmed_receipts(result)
    assert_receive {:adapter_edit, "room", "streamed", "answer", opts}
    assert opts[:uploaded_files] == [%{id: "uploaded-0"}]
    refute_received {:adapter_send, _, _, _}
  end

  test "unknown logical publication sizes never satisfy numeric encoded ceilings" do
    assert :ok = Preparation.validate_request(%{size_bytes: :unresolved}, :not_applicable)
    assert :ok = Preparation.validate_request(%{size_bytes: :unresolved}, :unresolved)

    assert {:error, :invalid_prepared_request} =
             Preparation.validate_request(%{size_bytes: :unresolved}, 10_000)
  end

  test "continue publishes only attested partial-upload identities and never guesses an uploaded prefix" do
    for {url, expected} <- [{"partial", [%{id: "known-second"}]}, {"ambiguous", nil}] do
      connection = %{connection() | url: url}
      original = outgoing()

      outgoing = %{
        original
        | attachments: original.attachments ++ [%{hd(original.attachments) | id: "two"}]
      }

      assert {:ok, snapshot} = JidoChatBridge.capability_snapshot(connection)
      assert {:ok, requirements} = TransportRequirements.resolve(snapshot, connection)
      assert {:ok, plan} = Attachments.build_plan(outgoing, requirements)
      assert {:ok, result} = Executor.execute(outgoing, plan, JidoChatBridge, connection)
      assert_receive {:adapter_send, "room", "answer", opts}
      assert opts[:uploaded_files] == expected
      assert {:ok, evidence} = Result.safe_evidence(result)
      assert evidence.parts != []
      refute_received {:adapter_send, _, _, _}
    end
  end

  test "text delivery keeps the selected SDK formatting path" do
    connection = connection()
    outgoing = %{outgoing() | attachments: [], metadata: %{format: :markdown}}
    assert {:ok, %{confirmation: :confirmed}} = JidoChatBridge.send_reply(outgoing, connection)
    assert_receive {:adapter_send, "room", "answer", opts}
    assert opts[:format] == :markdown
    refute_received {:adapter_upload, _}
  end

  defp connection do
    Code.ensure_loaded!(FileDeliveryAdapter)

    %{
      provider: :mattermost,
      url: "https://external.fixture",
      token: self(),
      settings: %{},
      opts: [config: FileDeliveryAdapter],
      delivery_channel_id: "room"
    }
  end

  defp outgoing do
    %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: "answer",
      attachments: [
        %Record{
          id: "one",
          kind: :file,
          content: <<0, 255>>,
          size: 2,
          name: "binary.dat",
          mime_type: "application/octet-stream"
        }
      ]
    }
  end
end
