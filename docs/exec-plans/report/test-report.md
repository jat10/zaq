  Headline
  Total real async: false test modules: 149.

  Root Cause Counts

  Application env/global config mutation                 62
  globally registered process / singleton process        13
  shared ETS / persistent_term / global cache             7
  global Mox/mock mode                                    5
  shared PubSub topic / shared messaging                  2
  OS environment variable mutation                        6
  shared external process/runtime                         3
  shared HTTP server / port / Finch pool                 13
  Oban/shared job runtime                                 3
  Ecto sandbox child-process ownership/shared sandbox     5
  database DDL/schema mutation                            9
  deliberate timing/concurrency integration               2
  true production singleton invariant                     3
  no clear reason / probably unnecessarily synchronous   16

  Top Systemic Causes

  1. Application.put_env/3 is still used as dependency injection in channels, ingestion, BO LiveViews, Agent runtime, storage, and system config tests.
     Evidence: lib/zaq/runtime_deps.ex, lib/zaq/config.ex, many Application.put_env setup blocks.

  2. Storage/Ingestion still read global runtime config in many paths. Evidence: Zaq.Storage, Zaq.Ingestion, Zaq.Ingestion.DocumentProcessor,
     FileExplorer, SourcePath.

  3. DataCase has global side effects even for DB tests: shared sandbox for non-async modules and global EventRegistry unregister/restore. Evidence:
     test/support/data_case.ex:36, :58-82.

  4. Runtime singleton processes: EventRegistry, Telemetry.Buffer, FeatureStore, RequestRegistry, PortalState, LogCollector.
  5. Local HTTP/LLM integration tests rely on Bandit/OpenAIStub and shared ReqLLM.Finch. Evidence: test/support/openai_stub.ex:20-47,
     finch_pool_contention_test.exs.

  Highest-Leverage Targets

  1. Add per-call/per-socket config injection for BO LiveViews and channels. Unlocks system_config_live 207, ingestion_live 194, jido_chat_bridge 170,
     jido_connect_bridge 158.

  2. Replace channel bridge Application DI keys with explicit runtime deps/options. Unlocks ~600 channel tests.
  3. Finish Storage config injection. Unlocks StorageTest 60, FileExplorerTest 93, SourcePathTest 12, file preview/controller tests.
  4. Split DDL chunk-table tests from non-DDL ingestion tests. DocumentProcessorTest has 124 tests but only some mutate ingestion config/DDL-like chunk
     behavior.

  5. Move ingestion worker collaborator selection from app env to args/opts. Unlocks IngestionTest, IngestWorkerTest, IngestChunkWorkerTest.
  6. Redesign DataCase.isolate_event_registry/0; avoid unregistering the singleton globally for every DataCase test.
  7. Make Agent runtime dependency seams option-based instead of app-env-based. Unlocks ServerManagerTest, MCP tests, nested workflow/agent tests.
  8. Give OpenAI/LLM tests isolated Finch pools or explicit non-pooled client config so ephemeral Bandit servers are not a suite-level concern.
  9. Isolate FeatureStore/LogCollector/RequestRegistry behind named instances where tests can pass a server/table name.
  10. Flip historical/no-clear modules after targeted validation.

  Likely Safe To Flip Soon
  Zaq.Ingestion.DocumentChunkerTest, Zaq.Storage.ApiTest, Zaq.System.OutboundHttpPolicyTest, Zaq.UserPortal.ProvisionerTest,
  ZaqWeb.MessageTraceArtifactControllerTest, ZaqWeb.Live.BO.Communication.ChannelsIndexLiveTest, ZaqWeb.Live.BO.ConversationsMetricsLiveTest,
  ZaqWeb.Live.BO.LLMPerformanceLiveTest, Zaq.Channels.WebhookUrlTest, Zaq.Agent.OpaqueAliasesTest, Zaq.Agent.RuntimeSyncTest.

  These showed no real module-wide global mutation, or use per-test data/opts. Validate individually with repeated async runs before bulk flipping.

  Should Remain Sync
  MessageFormatterEarmarkTest replaces the Earmark module VM-wide. FinchPoolContentionTest mutates the live ReqLLM.Finch supervisor child.
  ChunkResetTableTest, FTSBackendTest, EnrichmentChunkTableTest, migration/release tests, and SystemTest DDL cases mutate DB schema. FeatureStoreTest,
  LogCollectorTest, RequestRegistryTest, PortalStateTest, E2EControllerTest, and EventRegistryTest verify real singleton/cache behavior.

  Split Candidates
  High-value split candidates: system_config_live, ingestion_live, jido_chat_bridge, jido_connect_bridge, document_processor, ingestion, storage,
  file_explorer, conversations, workflow_run_agent, node_router, log_filter, notification, system.

  Incorrect/Outdated Comments
  test/zaq/engine/workflows/async_launch_test.exs and send_leads_email_thread_test.exs mention async: false in comments but are now async: true.
  dispatch_event_agent_tool_test.exs blames OpenAIStub port binding; the stronger reason is the registered observer/task boundary.
  Storage.ApiTest still appears synchronous historically; it already injects storage config through event opts.
  Agent.Tools.Web.BrowsingTest is correctly sync for OS env mutation, not DDL despite containing a “drop table” string.