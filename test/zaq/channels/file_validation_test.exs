defmodule Zaq.Channels.FileValidationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.StreamEvents
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Channels.{Api, Bridge, CommunicationBridge, JidoChatBridge, TransportRequirements}
  alias Zaq.Channels.Delivery.{Attachments, Executor}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Event

  defmodule Adapter do
    defp test_process, do: List.last(Process.get(:"$callers", [self()]))

    def validate_files(records, opts) do
      send(test_process(), {:validated, records, opts})

      case Enum.find(records, &(&1.size > opts[:max_file_size])) do
        nil ->
          :ok

        record ->
          {:error,
           {:file_too_large,
            %{filename: record.name, size: record.size, limit: opts[:max_file_size]}}}
      end
    end
  end

  defmodule Config do
    def get(:zaq, :channels, _default), do: %{mattermost: %{adapter: Adapter}}
  end

  defmodule Resolver do
    def bridge_for(:mattermost), do: JidoChatBridge

    def fetch_connection_details_for_config(config),
      do: Bridge.fetch_connection_details_for_config(config)
  end

  defmodule Router do
    def dispatch(%Event{request: %Outgoing{}} = event) do
      send(event.actor.test_pid, {:validation_event, event})
      event = %{event | opts: event.opts ++ [bridge_module: Resolver, config: Config]}
      Api.handle_event(event, :validate_files, %{})
    end
  end

  defmodule UnavailableRouter do
    def dispatch(_event), do: {:error, :no_channels_node}
  end

  defmodule SelectionStatus do
    def broadcast(incoming, _stage, _message, _router, _opts), do: incoming
  end

  defmodule DeliveryBridge do
    def transport_requirements(_outgoing, connection), do: {:ok, connection.requirements}

    def prepare_upload_request(files, _connection),
      do: {:ok, %{encoded_bytes: 0, request: files}}

    def execute_delivery_step(step, _inputs, connection) do
      send(connection.test_pid, {:transport_started, step.operation})

      if step.operation == :upload do
        {:ok,
         %{
           uploaded_attachments:
             Enum.map(step.attachment_refs, &%{id: "file-#{&1}", attachment_index: &1})
         }}
      else
        {:ok, %{confirmation: :confirmed, message_id: "post-#{step.group_id}", action: :created}}
      end
    end
  end

  defmodule LegacyAdapter do
    def capabilities, do: %{configurable_max_file_size: :native}
  end

  defmodule LegacyConfig do
    def get(:zaq, :channels, _default), do: %{mattermost: %{adapter: LegacyAdapter}}
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "preflight-#{System.unique_integer([:positive])}",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://preflight.example.invalid",
        token: "test-only-token",
        settings: %{"max_file_size" => 10}
      })
      |> Repo.insert!()

    incoming = %Incoming{
      content: "attach",
      provider: :mattermost,
      channel_id: "destination",
      routing_context: %RoutingContext{channel_config_id: config.id}
    }

    context = %{
      incoming: incoming,
      request_id: "request",
      state: %{requests: %{"request" => %{status: :pending}}},
      actor: %{person_id: 1, test_pid: self()},
      skip_permissions: true,
      node_router: Router
    }

    %{context: context}
  end

  test "authorized lazy Records reach the destination adapter through a synchronous event", %{
    context: context
  } do
    record = record(10)
    assert {:ok, %{records: [^record]}} = select_files("add", [record], context)
    assert_receive {:validation_event, %Event{} = event}
    assert event.actor == context.actor
    assert event.next_hop.type == :sync
    assert event.opts[:action] == :validate_files
    assert event.opts[:confidential]
    assert event.request.routing_context == context.incoming.routing_context
    assert_receive {:validated, [%Record{content: nil, size: 10}], opts}
    assert opts[:max_file_size] == 10
  end

  property "one oversized file returns rejection details regardless of batch position", %{
    context: context
  } do
    check all(size <- integer(11..100_000), position <- integer(0..2), max_runs: 15) do
      records = List.insert_at([record(0), record(10)], position, record(size))

      assert {:ok, %{records: selected, errors: [failure]}} =
               select_files("replace", records, context)

      assert selected == [record(0), record(10)]

      assert failure == %{
               record_id: "file-#{size}",
               name: "file-#{size}",
               reason: "file_too_large",
               size: size,
               limit: 10
             }

      assert_receive {:validated, ^records, opts}
      assert opts[:max_file_size] == 10

      assert {:ok, %{records: [], errors: [^failure]}} =
               select_files("replace", [record(size)], context)
    end
  end

  test "abort prevents transport after an oversized selection is retried with a valid subset", %{
    context: context
  } do
    config = Repo.get!(ChannelConfig, context.incoming.routing_context.channel_config_id)

    config
    |> ChannelConfig.changeset(%{
      settings: %{"max_file_size" => 307_200, "send_on_file_failure" => false}
    })
    |> Repo.update!()

    records =
      Enum.map(1..13, fn index ->
        {:ok, record} =
          Provenance.seal(%Record{
            id: "zaq-file-#{index}",
            kind: :file,
            name: "zaq-file-#{index}.txt",
            size: if(index == 2, do: 307_201, else: 1),
            content: if(index == 2, do: nil, else: "x")
          })

        record
      end)

    assert {:ok, first_instruction} = select_files("replace", records, context)

    failure = %{
      record_id: "zaq-file-2",
      name: "zaq-file-2.txt",
      reason: "file_too_large",
      size: 307_201,
      limit: 307_200
    }

    assert first_instruction.errors == [failure]
    assert length(first_instruction.records) == 12
    assert_receive {:validated, _, validation_opts}
    assert validation_opts[:max_file_size] == 307_200

    remaining = Enum.reject(records, &(&1.id == "zaq-file-2"))
    assert {:ok, instruction} = select_files("replace", remaining, context)
    assert length(instruction.records) == 12

    events = [
      %{
        kind: :tool_completed,
        at_ms: 1,
        tool_call_id: "rejected",
        data: %{tool_name: "attach_documents", result: {:ok, first_instruction, []}}
      },
      %{
        kind: :tool_completed,
        at_ms: 2,
        tool_call_id: "subset",
        data: %{tool_name: "attach_documents", result: {:ok, instruction, []}}
      },
      %{kind: :request_completed, at_ms: 3, data: %{result: "Here are the remaining files."}}
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, context.incoming,
               status_module: SelectionStatus,
               opaque_alias_scope: self()
             )

    outgoing = Outgoing.from_pipeline_result(context.incoming, result)
    assert Outgoing.Delivery.selection_failures(outgoing.delivery.error) == [failure]

    restored =
      %{delivery: Map.from_struct(result.delivery)}
      |> Jason.encode!()
      |> Jason.decode!()
      |> Outgoing.Delivery.from_result()

    assert Outgoing.Delivery.selection_failures(restored.error) == [failure]

    connection = %{
      test_pid: self(),
      requirements: %TransportRequirements{
        failure_policy: :abort,
        transfer_mode: :upload_then_publish,
        max_attachments_per_message: 10,
        max_attachment_bytes: 307_200,
        max_attachment_bytes_per_message: :not_applicable,
        max_encoded_message_bytes: :not_applicable,
        max_upload_request_bytes: :not_applicable,
        supports_threads: true
      }
    }

    response =
      with {:ok, planned} <- Attachments.build_plan(outgoing, DeliveryBridge, connection) do
        Executor.execute(planned, DeliveryBridge, connection)
      end

    refute_received {:transport_started, _}
    assert {:error, %{stage: :selection, cause: %{failures: [^failure]}}} = response

    assert CommunicationBridge.delivery_observation(DeliveryBridge, outgoing, response) == %{
             outcome: :failed,
             reason: :attachment_selection_failed,
             attachment_failures: [failure]
           }

    connection = put_in(connection.requirements.failure_policy, :continue)
    assert {:ok, planned} = Attachments.build_plan(outgoing, DeliveryBridge, connection)
    assert {:ok, report} = Executor.execute(planned, DeliveryBridge, connection)
    assert report.confirmation == :partial

    assert [%{stage: :selection, attachment_index: nil, selection_failure: ^failure}] =
             report.failed_attachments

    assert Enum.sum(Enum.map(report.messages, &length(&1.delivered_attachment_indices))) == 12
    assert List.last(outgoing.delivery.attachments).id == "zaq-file-13"
    refute Enum.any?(outgoing.delivery.attachments, &(&1.id == "zaq-file-2"))
    assert_received {:transport_started, :upload}
    assert_received {:transport_started, :send}

    abort_connection = put_in(connection.requirements.failure_policy, :abort)
    all_rejected = %{outgoing | delivery: %{outgoing.delivery | attachments: []}}

    assert {:error, %{stage: :selection, delivery: :not_sent, cause: %{failures: [^failure]}}} =
             Attachments.build_plan(all_rejected, DeliveryBridge, abort_connection)

    assert {:ok, text_plan} = Attachments.build_plan(all_rejected, DeliveryBridge, connection)
    assert {:ok, text_report} = Executor.execute(text_plan, DeliveryBridge, connection)
    assert [%{delivered_attachment_indices: []}] = text_report.messages
    assert [%{selection_failure: ^failure}] = text_report.failed_attachments
  end

  test "remove and clear do not need destination validation", %{context: context} do
    assert {:ok, _} = select_files("remove", [record(100)], context)
    assert {:ok, _} = select_files("replace", [], context)
    refute_receive {:validation_event, _}
  end

  test "workflow Incoming without a provider defers validation until a destination is known", %{
    context: context
  } do
    incoming = %{context.incoming | provider: nil}
    assert {:ok, _} = select_files("add", [record(100)], %{context | incoming: incoming})
    refute_receive {:validation_event, _}
  end

  test "content is not sent to validation and successful selection retains the original", %{
    context: context
  } do
    record = %{record(1) | content: "a"}
    assert {:ok, %{records: [^record]}} = select_files("add", [record], context)
    assert_receive {:validated, [%Record{content: nil}], _}
  end

  test "failed authorization never reaches validation", %{context: context} do
    context = %{context | actor: nil, skip_permissions: false}
    assert {:error, _} = select_files("add", [record(1)], context)
    refute_receive {:validation_event, _}
  end

  test "routing failures return to the tool", %{context: context} do
    assert {:error, error} =
             select_files("add", [record(1)], %{context | node_router: UnavailableRouter})

    assert inspect(error) =~ "no_channels_node"
  end

  test "an invalid destination connector fails instead of validating with another connector", %{
    context: context
  } do
    incoming = %{context.incoming | routing_context: %RoutingContext{channel_config_id: -1}}
    assert {:error, error} = select_files("add", [record(1)], %{context | incoming: incoming})
    assert inspect(error) =~ "invalid_connector_id"
    refute_receive {:validated, _, _}
  end

  test "an adapter without validation accepts selection regardless of configurable limits" do
    outgoing = %Outgoing{body: "", provider: :mattermost, channel_id: "room"}

    assert :ok = JidoChatBridge.validate_files(outgoing, %{}, config: LegacyConfig)
  end

  defp select_files(operation, records, context),
    do: Jido.Exec.run(AttachDocuments, %{operation: operation, records: records}, context)

  defp record(size) do
    {:ok, record} =
      Provenance.seal(%Record{id: "file-#{size}", kind: :file, name: "file-#{size}", size: size})

    record
  end
end
