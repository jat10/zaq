# Synchronous Test Wall Investigation - 2026-09-08

Scope: read-only investigation of remaining `async: false` test modules after prior config-injection refactors.

Baseline provided:

```text
Finished in 424.6 seconds
45.9s async
378.6s sync
48 doctests, 83 properties, 8538 tests
0 failures
```

Method:

- Enumerated `async: false` modules with `rg`.
- Timed each matching file with `mix test <file> --seed 0`.
- Used ExUnit "Finished in" runtime as the isolated runtime. Shell wall time includes repeated Mix startup and is not used for ranking.
- Inspected top files for `Application.put_env/get_env`, global process names, code reload, Mox, Oban, PubSub, Finch, ETS/persistent-term, DDL, OS env, and sleeps.

Notes:

- `bw prime` could not run in this environment: `bw: command not found`.
- One isolated timing run for `test/zaq/agent/server_manager_test.exs` failed after 22.7s on an `{:already_registered, pid}` drain-timeout case. The timing is still useful and reinforces the registered-singleton diagnosis.
- Some `async: false` files have all tests excluded by default; they do not materially contribute to the provided baseline unless excluded tags are included.

## Headline

The remaining synchronous wall is not primarily owned by individual slow assertions. It is dominated by a small number of large synchronous UI/integration modules plus broad architectural serialization from global configuration and singleton runtimes.

The two largest isolated files alone account for about 122s of isolated sync runtime:

- `SystemConfigLiveTest`: 61.6s, 207 static tests
- `IngestionLiveTest`: 60.7s, 194 static tests

The next tier is architectural rather than purely slow:

- `ServerManagerTest`: 22.7s, registered Jido/AgentServer lifecycle, flaky isolated run
- `CommunicationBridgeTest`: 21.3s, runtime recompilation of `Zaq.Channels.Bridge` plus `Application.put_env(:zaq, :channels, ...)`
- `ZAQRouterTest`: 16.3s for only 3 tests, global LLMDB catalog reload
- `ImageToTextTest`: 17.1s for 9 tests, Python runner/scripts-dir global config

## Top 20 Synchronous Modules By Isolated Runtime

| Rank | Module | File | Tests | Isolated runtime | Primary reason for async:false | Shared/global resource | Potential isolation strategy | Difficulty | Split candidate |
|---:|---|---|---:|---:|---|---|---|---|---|
| 1 | `ZaqWeb.Live.BO.System.SystemConfigLiveTest` | `test/zaq_web/live/bo/system/system_config_live_test.exs` | 207 | 61.6s | Global app env test stubs plus Mox/NodeRouter LiveView flows | `:mcp_test_module`, `:node_router_module`, `:litellm_base_url`, persisted global settings, Mox router | Inject LiveView dependency bundle through session/config opts; move test stubs out of Application env | high | yes |
| 2 | `ZaqWeb.Live.BO.AI.IngestionLiveTest` | `test/zaq_web/live/bo/ai/ingestion_live_test.exs` | 194 | 60.7s | Global app env test stubs and storage base path | `Zaq.Ingestion`, `Zaq.Storage`, `:ingestion_data_source_bridge_module`, provider response env keys | Inject bridge/router/storage deps into LiveView or context boundary; per-test stub process/state | high | yes |
| 3 | `Zaq.Agent.ServerManagerTest` | `test/zaq/agent/server_manager_test.exs` | 46 | 22.7s, failed once | Registered AgentServer lifecycle and global runtime config | Jido registry, `Zaq.Agent.AgentServerSupervisor`, `:agent_runtime_sync_module`, drain timeout env | Per-test registry/supervisor namespace and runtime opts | high | yes |
| 4 | `Zaq.Channels.CommunicationBridgeTest` | `test/zaq/channels/communication_bridge_test.exs` | 66 | 21.3s | Runtime module recompilation plus channel env mutation | `Zaq.Channels.Bridge` code server, `:channels` app env | Replace compile-time monkeypatch with explicit bridge resolver/dependency injection | high | yes |
| 5 | `Zaq.Ingestion.Python.Steps.ImageToTextTest` | `test/zaq/ingestion/python/steps/image_to_text_test.exs` | 9 | 17.1s | Python runner scripts-dir override | `Application.get_env(:zaq, Runner)` | Pass scripts dir through runner opts/config object | medium | no |
| 6 | `Zaq.Agent.ZAQRouterTest` | `test/zaq/agent/zaq_router_test.exs` | 3 | 16.3s | Global LLMDB reload/catalog mutation | LLMDB provider catalog | Namespaced/test-local LLMDB catalog or isolated reload API | high | no |
| 7 | `Zaq.Ingestion.DocumentProcessorTest` | `test/zaq/ingestion/document_processor_test.exs` | 124 static, 111 active + 4 props | 9.1s | App env/Mox/Finch/ETS/Oban integration mix | processor deps, FTS/cache, Finch, Oban workers | Processor dependency bundle passed through opts/events; isolate/reset caches | medium | yes |
| 8 | `Zaq.System.MachineSignalsTest` | `test/zaq/system/machine_signals_test.exs` | 31 | 8.7s | OS/system probing and env/config dependencies | OS env/system signal source | Injectable system-probe boundary | medium | no |
| 9 | `ZaqWeb.Live.BO.AI.TriggersLiveTest` | `test/zaq_web/live/bo/ai/triggers_live_test.exs` | 26 | 8.0s | LiveView + Mox/process dependencies | Mox router, LiveView process/DB sandbox | Per-test router injection and explicit Mox allowances | medium | maybe |
| 10 | `ZaqWeb.Live.BO.AI.FilePreviewLiveTest` | `test/zaq_web/live/bo/ai/file_preview_live_test.exs` | 13 | 7.2s | LiveView + storage/app env | storage preview config/runtime | Inject preview/storage deps | medium | maybe |
| 11 | `Zaq.Ingestion.Python.PipelineTest` | `test/zaq/ingestion/python/pipeline_test.exs` | 15 | 7.1s | Python runtime/config integration | runner config/scripts/runtime | Pass runner deps/options explicitly | medium | no |
| 12 | `Zaq.Channels.EmailBridge.ImapAdapterTest` | `test/zaq/channels/email_bridge/imap_adapter_test.exs` | 51 | 6.8s | Email runtime/Mox/sleeps | adapter runtime and mocks | Process-private mock ownership and injectable runtime deps | medium | maybe |
| 13 | `Zaq.Channels.JidoConnectBridgeTest` | `test/zaq/channels/jido_connect_bridge_test.exs` | 158/159 | 6.5s | `Application.put_env(:zaq, :channels, ...)` | channel bridge config | Bridge/config injection through opts or `Zaq.Config` | medium | yes |
| 14 | `ZaqWeb.Live.BO.System.AddonsLiveTest` | `test/zaq_web/live/bo/system/addons_live_test.exs` | 21 | 6.5s | LiveView/PubSub/shared DB flow | PubSub and sandbox-owned processes | Explicit process ownership; split pure render tests | medium | maybe |
| 15 | `Zaq.Channels.JidoChatBridgeTest` | `test/zaq/channels/jido_chat_bridge_test.exs` | 170 | 6.4s | `:channels` env plus PubSub/Oban bridge flows | channel bridge config, PubSub, Oban | Bridge/config injection; split pure routing cases from runtime cases | medium | yes |
| 16 | `Zaq.Agent.Tools.Web.BrowsingTest` | `test/zaq/agent/tools/web/browsing_test.exs` | 30 | 5.9s | OS env mutation | browser-related env vars | Inject browser env/config boundary | low/medium | no |
| 17 | `Zaq.Agent.Tools.RegistryTest` | `test/zaq/agent/tools/registry_test.exs` | 25 | 5.3s | Global registry/catalog | tool registry | Per-test registry namespace | medium | no |
| 18 | `Zaq.Engine.Workflows.Steps.BatchSequentialTimingTest` | `test/zaq/engine/workflows/steps/batch_sequential_timing_test.exs` | 5 | 3.6s | Deliberate timing/concurrency integration | workflow timing semantics | Keep sync unless runner gets deterministic scheduler hooks | high | no |
| 19 | `ZaqWeb.Live.BO.DataSources.ProviderLiveTest` | `test/zaq_web/live/bo/data_sources/provider_live_test.exs` | 62 | 3.5s | Channel app env + LiveView | `:channels` provider config | Inject channel provider config into LiveView/context | medium | yes |
| 20 | `Zaq.StorageTest` / `ZaqWeb.FileControllerTest` | `test/zaq/storage_test.exs`, `test/zaq_web/controllers/file_controller_test.exs` | 64 / 10 | 3.4s each | Storage env/filesystem + ConnCase | storage base path/config | Per-test storage config through opts/events | medium | maybe |

## Root Causes Ranked By Cumulative Runtime

| Root cause | Modules | Tests | Approx cumulative isolated runtime | Largest modules | Likely systemic fix |
|---|---:|---:|---:|---|---|
| BO LiveView dependency stubs via global config/Mox/session | ~9 | ~541 | ~153s | `system_config_live`, `ingestion_live`, `triggers_live`, `file_preview_live`, `addons_live` | Add LiveView/context dependency injection for router, MCP, ingestion bridge, storage, provider browser, and create-document deps |
| Channels `:channels` app env and bridge resolver/global module mutation | ~16 | ~950 | ~55s | `communication_bridge`, `jido_chat_bridge`, `jido_connect_bridge`, `data_source_bridge`, `imap_adapter` | Route all bridge/provider lookup through injectable resolver/config, remove runtime code recompilation |
| Agent singleton/global runtime/catalog | ~10 | ~230 | ~55s | `server_manager`, `zaq_router`, `tools/registry`, `factory`, integration flows | Per-test registry/supervisor/catalog namespace; replace app-env runtime deps with opts |
| Ingestion Python/runtime process | 3 | ~50 | ~27s | `image_to_text`, `pipeline`, `runner` | Pass Python runner config/scripts dir as opts; isolate external process runtime |
| Core ingestion env/Mox/Oban/ETS | ~10 | ~440 | ~20s | `document_processor`, `ingestion_test`, `ingest_worker`, `file_explorer` | Processor/dependency bundle via opts/events; cache isolation/reset helpers |
| Workflow concurrency/Ecto sandbox/Oban | ~13 | ~115 | ~18s | `batch_sequential_timing`, `orphaned_run_recovery`, `lead_pipeline_e2e`, `finch_pool_contention` | Explicit child process DB ownership and per-test workflow runtime; keep true timing tests sync |
| OS env/system probes | ~5 | ~95 | ~16s | `machine_signals`, `browsing`, `user_portal/client` | Injectable OS/system boundary and process-local env adapter |
| Storage/filesystem config | ~5 | ~240 | ~9s | `storage_test`, `file_controller`, `file_explorer`, `source_path` | Per-call/event storage config instead of global base path |
| Telemetry shared collector/cache | ~5 | ~56 | ~2s | `buffer_collector`, telemetry workers | Low priority; use per-test collector/buffer name if needed |
| DDL/schema mutation | ~5 active default | ~50 active | <2s default | `chunk_reset_table`, migration/release tests | Keep sync |

## Top 10 Targets By Expected Wall-Clock Leverage

1. BO LiveView dependency injection for `system_config_live_test` and `ingestion_live_test`.
   - Highest cumulative runtime and test count.
   - One architectural pattern unlocks both giant files and several smaller LiveViews.
   - Risk: high because it crosses LiveView/context boundaries.

2. Channels bridge/config resolver injection.
   - Unlocks hundreds of tests across `jido_chat_bridge`, `jido_connect_bridge`, `data_source_bridge`, `bridge`, `supervisor`, provider LiveView, and some engine connect tests.
   - Risk: medium/high, but blast radius is bounded to channel provider lookup.

3. Remove runtime recompilation from `CommunicationBridgeTest`.
   - Directly targets a 21.3s isolated module.
   - Also removes a severe global code-server mutation.
   - Risk: high but worthwhile; likely requires a production-meaningful resolver seam.

4. Agent runtime namespace isolation.
   - Targets `server_manager_test` and related registry/runtime tests.
   - Also addresses the observed isolated flake.
   - Risk: high due to Jido/AgentServer lifecycle.

5. Python runner config injection.
   - Directly targets ~27s with smaller blast radius than BO/Agent.
   - Risk: medium.

6. Ingestion document processor dependency bundle.
   - Unlocks `document_processor_test`, parts of `ingestion_test`, and worker tests.
   - Risk: medium.

7. Storage config injection completion.
   - Unlocks many tests, but the explicitly identified `source_path_test` is cheap.
   - Best done when touching FilePreview/Ingestion LiveView.

8. OS/system probe boundary.
   - Targets `machine_signals_test` and `browsing_test`.
   - Risk: medium; good cleanup but less systemic than BO/channels.

9. Workflow process ownership improvements.
   - Helps several medium files.
   - Some should intentionally remain sync because concurrency/timing is the behavior.

10. Telemetry collector isolation.
   - Low runtime leverage. Do not prioritize unless nearby work already touches telemetry.

## Recommended Next Refactor

Start with BO LiveView dependency injection for `ZaqWeb.Live.BO.AI.IngestionLive`.

Reasoning:

- `ingestion_live_test` is 60.7s isolated with 194 tests.
- The file clearly uses `Application.get_env/put_env` as stub state for provider browsing, create-document responses, ingestion call routing, storage base path, and node-router responses.
- The same architectural smell appears in `system_config_live_test`, so the seam should be designed once and reused.
- This target has better leverage than storage-only or EventRegistry work, because it removes a full LiveView suite from sync and creates a pattern for the largest remaining module.

Expected modules unlocked or partially unlocked:

- `test/zaq_web/live/bo/ai/ingestion_live_test.exs`
- `test/zaq_web/live/bo/system/system_config_live_test.exs`
- `test/zaq_web/live/bo/ai/file_preview_live_test.exs`
- `test/zaq_web/live/bo/ai/file_preview_data_test.exs`
- `test/zaq_web/live/bo/data_sources/provider_live_test.exs`
- `test/zaq_web/controllers/file_controller_test.exs`

## Channels Finding

The large Channels suites are still primarily synchronous because of `Application.put_env(:zaq, :channels, ...)`, but that is not the whole story.

Evidence:

- `jido_chat_bridge_test` repeatedly mutates `:channels`; 170 tests, 6.4s isolated.
- `jido_connect_bridge_test` repeatedly mutates `:channels`; ~159 tests, 6.5s isolated.
- `data_source_bridge_test`, `bridge_test`, `supervisor_test`, and provider LiveView also mutate/read `:channels`.
- `communication_bridge_test` is much more severe: it both mutates `:channels` and purges/deletes/recompiles `Zaq.Channels.Bridge` during setup. That code-server mutation is a true VM-global resource and explains the 21.3s isolated runtime.
- After the MessageFormatter and EmailBridge config refactors, the remaining Channels sync wall is now mostly bridge/provider resolver state, runtime process interactions, PubSub/Oban in a few cases, and one major monkeypatch-style test.

## Tests That Should Intentionally Remain Synchronous

Keep these sync until their underlying systems have explicit test-local namespaces or deterministic hooks:

- DDL/schema mutation:
  - `test/zaq/ingestion/chunk_reset_table_test.exs`
  - `test/zaq/ingestion/fts_backend_test.exs` where table/backend reset is involved
  - migration/release tests that mutate schema
- True global catalog/singleton:
  - `test/zaq/agent/zaq_router_test.exs` unless LLMDB can be namespaced
  - singleton registry/cache tests such as RequestRegistry/FeatureStore/LogCollector/PortalState when asserting the singleton invariant itself
- Deliberate timing/concurrency integration:
  - `test/zaq/engine/workflows/steps/batch_sequential_timing_test.exs`
  - `test/zaq/engine/workflows/finch_pool_contention_test.exs`
  - workflow E2E/fan-out tests that intentionally prove overlap, contention, or recovery semantics
- AgentServer lifecycle/drain tests:
  - keep sync until AgentServer registry/supervisor names are injectable per test

## Surprising Results

- `test/zaq/ingestion/source_path_test.exs` is explicitly global-config sync but only 0.1s isolated. It is not a good standalone priority.
- `test/zaq/engine/event_registry_test.exs` is only 0.7s for 40 tests. It may be architecturally interesting, but it is not a wall-clock owner.
- `test/zaq/agent/zaq_router_test.exs` is only 3 tests but costs 16.3s because it reloads the global LLMDB catalog.
- `test/zaq/ingestion/python/steps/image_to_text_test.exs` is only 9 tests but costs 17.1s because it exercises Python runner/script behavior.
- `test/zaq/channels/jido_chat_bridge_test.exs` and `test/zaq/channels/jido_connect_bridge_test.exs` are huge by test count but only about 6.5s each. They matter more for tests unlocked than for isolated runtime.
- Telemetry was cheaper than expected: the measured telemetry cluster is about 2s isolated.
- EventRegistry/DataCase was not a major timing owner in the measured pass, despite being architecturally global.

## Remaining Module Inventory

This inventory lists measured `async: false` files from the pass. Runtime is isolated ExUnit runtime unless noted.

| File | Runtime | Tests/count notes | Root-cause classification |
|---|---:|---|---|
| `test/mix/tasks/db_copy_test.exs` | 0.1s | 9 | Application env/global config |
| `test/mix/tasks/hooks_verify_test.exs` | 0.7s | 10 | Application env/global config |
| `test/mix/tasks/zaq/python/fetch_test.exs` | 0.3s | 8 | Application env/global config |
| `test/support/integration_agent_test.exs` | 0.1s | 1 static | Ecto sandbox/process |
| `test/zaq/addons/addons_integration_test.exs` | 0.1s | 3 excluded | Excluded/default non-owner |
| `test/zaq/addons/feature_store_test.exs` | 0.06s | 3 | true singleton/cache |
| `test/zaq/addons/oban_provisioner_test.exs` | 0.5s | 20 | Oban + app env |
| `test/zaq/addons/package_loader_test.exs` | 0.5s | 15 | package/runtime/DDL-like |
| `test/zaq/addons/post_loader_test.exs` | 0.2s | 9 | PubSub/DDL/runtime |
| `test/zaq/addons_integration_test.exs` | 0.1s | 5 excluded | Excluded/default non-owner |
| `test/zaq/agent/browser_flow_integration_test.exs` | 0.1s | 1 excluded | Excluded/default non-owner |
| `test/zaq/agent/chunk_title_coverage_test.exs` | 0.3s | 6 | Ecto sandbox/process |
| `test/zaq/agent/chunk_title_test.exs` | 0.3s | 5 active, 2 excluded | Ecto sandbox/process |
| `test/zaq/agent/disk_document_flow_integration_test.exs` | 2.4s | 1 static | Agent integration/runtime |
| `test/zaq/agent/executor_integration_test.exs` | 2.3s | 19 | Agent integration/runtime |
| `test/zaq/agent/factory_test.exs` | 1.9s | 42 | Agent runtime/config |
| `test/zaq/agent/history_loader_test.exs` | 1.3s | 24 | Ecto sandbox/process |
| `test/zaq/agent/http_request_flow_integration_test.exs` | 2.6s | 1 static | HTTP/Finch/runtime |
| `test/zaq/agent/materialization_alias_integration_test.exs` | 0.7s | 1 static | Ecto sandbox/process |
| `test/zaq/agent/mcp/runtime_test.exs` | 0.5s | 6 doctests, 36 tests | Agent runtime/app env |
| `test/zaq/agent/mcp/signal_adapter_test.exs` | 1.0s | 5 doctests, 2 tests | Agent MCP/runtime |
| `test/zaq/agent/mcp_test.exs` | 0.6s | 31 | Application env/global config |
| `test/zaq/agent/media_attachment_integration_test.exs` | 0.5s | 1 static | Mox/Ecto sandbox |
| `test/zaq/agent/nested_run_agent_integration_test.exs` | 0.9s | 4 | App env + Mox + workflow runtime |
| `test/zaq/agent/pipeline_test.exs` | 0.5s | 21 | Agent process/runtime |
| `test/zaq/agent/request_registry_test.exs` | 0.09s | 4 | true singleton/ETS |
| `test/zaq/agent/retrieval_coverage_test.exs` | 0.5s | 9 | Ecto sandbox/process |
| `test/zaq/agent/retrieval_test.exs` | 0.4s | 5 active, 2 excluded | Ecto sandbox/process |
| `test/zaq/agent/server_manager_test.exs` | 22.7s | 46, failed once | registered singleton/global process |
| `test/zaq/agent/skill/resource_provider_test.exs` | 2.9s | 2 properties, 20 tests | app env + ETS/runtime |
| `test/zaq/agent/tool_call_loop_stub_test.exs` | 0.8s | 2 | Agent integration/runtime |
| `test/zaq/agent/tools/messages/upsert_incoming_routing_rules_test.exs` | 0.6s | 13 | Ecto sandbox/process |
| `test/zaq/agent/tools/registry_test.exs` | 5.3s | 25 | registered singleton/global registry |
| `test/zaq/agent/tools/search_knowledge_base_integration_test.exs` | 0.1s | 4 excluded | Excluded/default non-owner |
| `test/zaq/agent/tools/web/browsing_test.exs` | 5.9s | 30 | OS env mutation |
| `test/zaq/agent/tools/workflow/dispatch_event_agent_tool_test.exs` | 0.7s | 2 | workflow/Mox/process |
| `test/zaq/agent/zaq_router_test.exs` | 16.3s | 3 | true singleton/global LLMDB |
| `test/zaq/application_test.exs` | 0.2s | 7 | Application/OS env |
| `test/zaq/channels/bridge_test.exs` | 0.8s | 37 | channels app env |
| `test/zaq/channels/channel_config_test.exs` | 0.8s | 49 | channels app env/DataCase |
| `test/zaq/channels/communication_bridge_test.exs` | 21.3s | 66 | code reload + channels app env |
| `test/zaq/channels/data_source_bridge_test.exs` | 1.9s | 1 property, 76 tests | channels app env |
| `test/zaq/channels/email_bridge/attachment_materialization_test.exs` | 0.4s | 1 static | channels app env |
| `test/zaq/channels/email_bridge/imap_adapter_test.exs` | 6.8s | 1 property, 50 tests | Mox/email runtime/app env |
| `test/zaq/channels/email_bridge/incoming_attachment_materialization_integration_test.exs` | 0.5s | 1 static | channels app env |
| `test/zaq/channels/email_bridge/smtp_sender_test.exs` | 2.4s | 33 | Ecto sandbox/email runtime |
| `test/zaq/channels/email_bridge/threading_headers_test.exs` | 0.2s | 11 | channels app env |
| `test/zaq/channels/email_bridge/tls_helpers_test.exs` | 0.1s | 2 | unnecessary/historical candidate |
| `test/zaq/channels/jido_chat_bridge/mattermost_reaction_ingress_test.exs` | 0.2s | 7 | channels app env + PubSub |
| `test/zaq/channels/jido_chat_bridge/reaction_event_test.exs` | 0.2s | 11 | channels app env |
| `test/zaq/channels/jido_chat_bridge/state_test.exs` | 0.5s | 23 | channels app env + PubSub/process |
| `test/zaq/channels/jido_chat_bridge/telegram_reaction_webhook_test.exs` | 0.2s | 3 | channels app env/process |
| `test/zaq/channels/jido_chat_bridge_test.exs` | 6.4s | 170 | channels app env + PubSub/Oban |
| `test/zaq/channels/jido_connect_bridge/webhook_worker_test.exs` | 0.9s | 4 | Oban/DataCase |
| `test/zaq/channels/jido_connect_bridge_coverage_gaps_test.exs` | 1.4s | 23 | channels app env + Oban/Finch |
| `test/zaq/channels/jido_connect_bridge_test.exs` | 6.5s | 158/159 | channels app env |
| `test/zaq/channels/message_formatter_earmark_test.exs` | 0.1s | 1 static | unnecessary/historical or Earmark global behavior |
| `test/zaq/channels/supervisor_test.exs` | 1.0s | 37 | channels app env + ETS/process |
| `test/zaq/channels/telegram_markdown_delivery_test.exs` | 0.3s | 11 | channels app env |
| `test/zaq/channels/webhook_url_test.exs` | 0.1s | 4 | likely unnecessary/historical |
| `test/zaq/e2e/log_collector_test.exs` | 0.07s | 6 | true singleton/log collector |
| `test/zaq/e2e/portal_state_test.exs` | 0.04s | 6 | true singleton/portal state |
| `test/zaq/embedding/client_test.exs` | 1.5s | 21 | app env + Finch |
| `test/zaq/engine/connect/grant_refresh_worker_test.exs` | 0.2s | 7 | Oban + channels app env |
| `test/zaq/engine/connect/oauth_test.exs` | 1.4s | 25 | app env/channels config |
| `test/zaq/engine/connect_encryption_error_test.exs` | 0.1s | 4 | app env/DataCase |
| `test/zaq/engine/connect_token_edge_cases_test.exs` | 0.3s | 10 | app env/DataCase |
| `test/zaq/engine/conversations/title_generation_from_conversations_test.exs` | 0.3s | 1 static | app env + PubSub/process |
| `test/zaq/engine/conversations/title_generator_coverage_test.exs` | 0.4s | 11 | Ecto sandbox/process |
| `test/zaq/engine/conversations/title_generator_test.exs` | 0.4s | 6 | Ecto sandbox/process |
| `test/zaq/engine/conversations_test.exs` | 2.3s | 124 | app env + sandbox/process |
| `test/zaq/engine/conversations_title_generation_integration_test.exs` | 0.9s | 3 | app env + PubSub/process |
| `test/zaq/engine/data_sources_test.exs` | 1.1s | 30 | app env + Oban |
| `test/zaq/engine/event_registry_test.exs` | 0.7s | 40 | EventRegistry/PubSub/process |
| `test/zaq/engine/notifications/email_threading_test.exs` | 0.7s | 10 | app env/DataCase |
| `test/zaq/engine/notifications/notification_test.exs` | 1.0s | 30 | app env/DataCase |
| `test/zaq/engine/notifications/outbound_threading_regression_test.exs` | 0.4s | 2 | app env/DataCase |
| `test/zaq/engine/notifications/user_notification_test.exs` | 0.6s | 1 property, 5 tests | app env/DataCase |
| `test/zaq/engine/telemetry/benchmark_connector/http_test.exs` | 0.2s | 4 | app env + OS env + Finch |
| `test/zaq/engine/telemetry/buffer_collector_test.exs` | 0.9s | 32 | telemetry collector/process |
| `test/zaq/engine/telemetry/telemetry_test.exs` | 0.6s | 13 | app env + OS env + registry |
| `test/zaq/engine/telemetry/workers/pull_benchmarks_worker_test.exs` | 0.3s | 5 | app env + Finch |
| `test/zaq/engine/telemetry/workers/push_rollups_worker_test.exs` | 0.2s | 2 | app env + Finch |
| `test/zaq/engine/trigger_node_link_test.exs` | 2.0s | 2 | Mox + process/timing |
| `test/zaq/engine/workflows/craft_email_trigger_test.exs` | 0.6s | 7 | Mox + PubSub/workflow |
| `test/zaq/engine/workflows/cron_trigger_worker_test.exs` | 0.3s | 8 | Oban + Mox |
| `test/zaq/engine/workflows/dispatch_batch_triggers_run_agent_test.exs` | 1.8s | 1 static | deliberate concurrency/process |
| `test/zaq/engine/workflows/dispatch_event_workflow_test.exs` | 0.7s | 1 static | workflow/Mox/process |
| `test/zaq/engine/workflows/finch_pool_contention_test.exs` | 1.8s | 1 static | HTTP/Finch contention |
| `test/zaq/engine/workflows/history_seeds_run_agent_test.exs` | 0.3s | 1 static | workflow/Mox/app env |
| `test/zaq/engine/workflows/lead_pipeline_e2e_test.exs` | 2.4s | 8 | workflow concurrency/Mox |
| `test/zaq/engine/workflows/log_filter_test.exs` | 0.2s | 10 | Ecto sandbox/process |
| `test/zaq/engine/workflows/orphaned_run_recovery_test.exs` | 3.2s | 11 | Oban/workflow recovery |
| `test/zaq/engine/workflows/run_recovery_worker_test.exs` | 0.3s | 7 | Oban/app env |
| `test/zaq/engine/workflows/send_leads_email_threading_e2e_test.exs` | 1.7s | 3 | workflow concurrency/Mox |
| `test/zaq/engine/workflows/steps/batch_sequential_timing_test.exs` | 3.6s | 5 | deliberate timing integration |
| `test/zaq/engine/workflows/workflow_run_agent_test.exs` | 1.5s | 47 | app env + PubSub/workflow |
| `test/zaq/hooks/registry_test.exs` | 0.1s | 8 | hooks registry/cache |
| `test/zaq/hooks_test.exs` | 0.5s | 30 | hooks global registry/app env |
| `test/zaq/ingestion/bm25_fusion_validation_test.exs` | 0.2s | 39 excluded | Excluded/default non-owner |
| `test/zaq/ingestion/chunk_reset_table_test.exs` | 0.2s | 3 | DDL/schema |
| `test/zaq/ingestion/chunk_verbatim_ingestion_test.exs` | 1.3s | 13 | app env + Mox + Oban/Finch/ETS |
| `test/zaq/ingestion/document_processor_test.exs` | 9.1s | 111 active, 4 props, 9 excluded | app env + Mox + Finch/ETS/Oban |
| `test/zaq/ingestion/enrichment_test.exs` | 0.2s | 3 | Ecto sandbox |
| `test/zaq/ingestion/file_explorer_test.exs` | 1.5s | 1 property, 92 tests | storage/app env |
| `test/zaq/ingestion/fts_backend_test.exs` | 0.5s | 4 props, 26 tests, 7 excluded | ETS/persistent cache + DDL |
| `test/zaq/ingestion/ingest_chunk_worker_test.exs` | 1.0s | 19 | app env + Oban |
| `test/zaq/ingestion/ingest_worker_test.exs` | 1.5s | 23, 1 skipped | app env + Mox + Oban/ETS |
| `test/zaq/ingestion/ingestion_record_test.exs` | 1.2s | 4 props, 5 tests | app env + Mox + Oban |
| `test/zaq/ingestion/ingestion_test.exs` | 2.6s | 81 | app env + Mox + PubSub/Oban/Finch |
| `test/zaq/ingestion/language_detector_test.exs` | 0.3s | 12 | app env |
| `test/zaq/ingestion/python/pipeline_test.exs` | 7.1s | 15 | Python runtime/config |
| `test/zaq/ingestion/python/runner_test.exs` | 2.6s | 26 | Python runner + OS env |
| `test/zaq/ingestion/python/steps/image_to_text_test.exs` | 17.1s | 9 | Python runner/scripts-dir config |
| `test/zaq/ingestion/record_source_sync_test.exs` | 0.1s | 1 static | OS env/Mox/DataCase |
| `test/zaq/ingestion/source_path_test.exs` | 0.1s | 12 | storage app env |
| `test/zaq/node_router_test.exs` | 0.5s | 29 | PubSub/registry |
| `test/zaq/oban/dynamic_cron_test.exs` | 0.8s | 33 | Oban + app env |
| `test/zaq/release_test.exs` | 0.07s | 3 | app env/DDL |
| `test/zaq/repo/migrations/migrate_disk_volumes_to_channel_config_test.exs` | 0.2s | 3 | migration/DDL |
| `test/zaq/runtime_deps_test.exs` | 0.04s | 2 | app env |
| `test/zaq/storage/volume_config_test.exs` | 0.2s | 1 property, 10 tests | storage app env |
| `test/zaq/storage_test.exs` | 3.4s | 4 properties, 60 tests | storage app env/filesystem/DDL |
| `test/zaq/system/ai_provider_credential_test.exs` | 0.3s | 14 | app env/DataCase |
| `test/zaq/system/machine_signals_test.exs` | 8.7s | 31 | OS/system probes |
| `test/zaq/system/release_update_test.exs` | 0.1s | 3 | app env/Finch |
| `test/zaq/system/secret_config_test.exs` | 0.1s | 17 | app env |
| `test/zaq/system/system_test.exs` | 1.2s | 54 | app env + ETS/DDL |
| `test/zaq/types/encrypted_string_test.exs` | 0.09s | 17 | app env |
| `test/zaq/user_portal/client_test.exs` | 0.9s | 24 | app env + OS env + Mox/Finch |
| `test/zaq/user_portal/onboarding_test.exs` | 1.9s | 15 | app env + Mox/DDL |
| `test/zaq_web/components/service_unavailable_test.exs` | 0.1s | 11 | Mox/ConnCase |
| `test/zaq_web/controllers/e2e_controller_test.exs` | 0.2s | 6 active, 10 excluded | E2E singleton/controller |
| `test/zaq_web/controllers/file_controller_test.exs` | 3.4s | 10 | storage app env + ConnCase |
| `test/zaq_web/live/bo/ai/file_preview_data_test.exs` | 1.0s | 11 | app env + Mox/DataCase |
| `test/zaq_web/live/bo/ai/file_preview_live_test.exs` | 7.2s | 13 | LiveView + storage app env |
| `test/zaq_web/live/bo/ai/ingestion_live_test.exs` | 60.7s | 194 | LiveView + app env stubs + Mox/Oban/PubSub |
| `test/zaq_web/live/bo/ai/knowledge_gap_live_test.exs` | 0.9s | 2 | PubSub/LiveView |
| `test/zaq_web/live/bo/ai/triggers_live_test.exs` | 8.0s | 26 | LiveView + Mox/process |
| `test/zaq_web/live/bo/data_sources/provider_live_test.exs` | 3.5s | 62 | LiveView + channels app env |
| `test/zaq_web/live/bo/system/addons_live_test.exs` | 6.5s | 21 | LiveView + PubSub/DataCase |
| `test/zaq_web/live/bo/system/onboarding_scenarios_integration_test.exs` | 3.0s | 5 | LiveView + app env + Mox/Finch |
| `test/zaq_web/live/bo/system/system_config_live_test.exs` | 61.6s | 1 property, 206 tests | LiveView + app env stubs + Mox/router |

