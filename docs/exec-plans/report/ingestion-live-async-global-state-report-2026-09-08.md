# IngestionLive Test Async Global-State Report

Date: 2026-09-08

Scope: `test/zaq_web/live/bo/ai/ingestion_live_test.exs` and the production paths it exercises.

Constraint: architectural report only; no implementation patches.

## A. Executive Summary

`test/zaq_web/live/bo/ai/ingestion_live_test.exs` is correctly serialized today because many tests mutate VM-wide `Application` config that changes behavior for every concurrently mounted `IngestionLive`, `RecordSource`, storage helper, and in-file stub. The largest issue is not one global key; it is that dependency selection and per-test fake behavior are both stored under global `:zaq` application env.

`ConnCase` database sandboxing is not enough to make this async-safe. The module also uses database-backed singleton config (`system.global.base_url`), fixed unique database fixtures, a shared PubSub topic, and app-env-selected filesystem roots.

The stubs defined inside `ingestion_live_test.exs` do use `Application.get_env/3` heavily. I found no use of `Application.put_env/3`, process registration, ETS, `persistent_term`, PubSub, OS environment mutation, or filesystem mutation inside those stubs themselves. They do send observation messages to a PID read from global application env.

`bw prime` could not run during this audit because `bw` was unavailable in the shell.

## B. Global-State Inventory

### Dependency Selection

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| `:ingestion_data_source_bridge_module` | Common setup restore path and provider tests, especially provider browsing setup around `Application.put_env(:zaq, :ingestion_data_source_bridge_module, ProviderBrowserBridgeStub)` | `IngestionLive.data_source_bridge_module/0`; `RecordSource.data_source_opts/1`; `RecordSource.data_source_context/1` | The mounted LiveView/event/request that needs that bridge | One test can swap another test's provider bridge while that other test is mounting or handling an event | Yes | Testing convenience |
| `:ingestion_call_module` | Ingestion call degradation tests set `IngestionCallStub` | `IngestionLive.ingestion_call/2` via `Zaq.Config.get(:zaq, :ingestion_call_module, NodeRouter, [])` | The mounted LiveView or routed request | One test's fake call module can intercept another test's job/retry/cancel/watch call | Yes | Testing convenience around a runtime seam |
| `:ingestion_create_document_module` | Upload and create-document error tests set `CreateDocumentStub` | `IngestionLive.create_document/2`; `SystemConfigLive` also has a create-document seam | The create-document action boundary for the test scenario | Provider create/upload behavior can change across unrelated tests | Yes | Testing convenience/runtime seam |
| `:ingestion_node_router_module` | Permission sync and ingestion error tests set `IngestionRouterStub` | `IngestionLive.dispatch_ingest_records/3`; `IngestionLive.dispatch_source_permission_sync/2` | The event dispatch/request owner | One test's router response controls another test's ingestion or permission dispatch | Yes | `NodeRouter` is production-global; replacement is testing convenience |

### Stub/Fake Behavior

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| `:provider_browser_response` | Provider error/custom record tests | `ProviderBrowserErrorBridgeStub.list_files/3`; `ProviderBrowserCustomBridgeStub.list_files/3` | The owning provider-browser test process/fake instance | A response intended for one scenario can be consumed by another LiveView | Yes | Testing convenience |
| `:provider_browser_list_response` | Not restored in common setup, but read by `ProviderBrowserBridgeStub` | `ProviderBrowserBridgeStub.list_files/3` | The owning provider-browser test process/fake instance | If any test sets it, all provider listing tests see it | Yes | Testing convenience |
| `:provider_browser_create_response` | Provider upload/deletion response tests and nested provider tests | `ProviderBrowserBridgeStub.create_file/3` | The owning create-file test process/fake instance | One test's create success/error can bleed into another test | Yes | Testing convenience |
| `:provider_browser_delete_response` | Provider deletion tests | `ProviderBrowserBridgeStub.delete_file/2` | The owning delete test process/fake instance | One delete scenario can change another test's deletion result | Yes | Testing convenience |
| `:provider_browser_permissions_response` | Permission and share-modal tests | `ProviderBrowserBridgeStub.list_permissions/3`; `ProviderBrowserCustomBridgeStub.list_permissions/3` | The owning permissions test process/fake instance | Permission result shape can bleed between tests | Yes | Testing convenience |
| `:provider_browser_replace_permissions_response` | Provider share failure tests | `ProviderBrowserBridgeStub.replace_permissions/3` | The owning share test process/fake instance | Permission replacement success/failure can bleed between tests | Yes | Testing convenience |
| `:provider_browser_scopes_response` | Source-scope tests and scoped provider root tests | `ProviderBrowserBridgeStub.list_source_scopes/2` | The owning source-scope test process/fake instance | One test's scopes can determine another test's active source | Yes | Testing convenience |
| `:provider_browser_watch_response` | Watch error/degradation tests | `ProviderBrowserBridgeStub.watch_item/2` | The owning watch test process/fake instance | Watch success/error can change another test's document status and flash assertions | Yes | Testing convenience |
| `:provider_browser_unwatch_response` | Unwatch response tests | `ProviderBrowserBridgeStub.unwatch_item/2` | The owning unwatch test process/fake instance | Unwatch success/error can bleed between tests | Yes | Testing convenience |
| `:provider_browser_capability_snapshot` | Provider capability/action CTA/watch tests | `ProviderBrowserBridgeStub.capability_snapshot/1`; capability dispatch path in `IngestionLive` | The owning capability test process/fake instance | Capabilities for one scenario can enable/disable another test's UI and dispatch paths | Yes | Testing convenience |
| `:ingestion_call_responses` | Ingestion call degradation and watch degradation tests | `IngestionCallStub.invoke/4` | The owning test process/fake instance | A fake response for `list_jobs`, `mark_watch_active`, etc. can affect another test's LiveView | Yes | Testing convenience |
| `:ingestion_create_document_response` | Create-document failure tests and mixed upload test | `CreateDocumentStub.run/2` | The owning create-document test process/fake instance | One test's function or error response can be used by another test | Yes | Testing convenience |
| `:ingestion_router_response` | Ingest/permission error tests | `IngestionRouterStub.dispatch/1` | The owning routed-dispatch test process/fake instance | One test's router error can make another test fail ingestion or permission sync | Yes | Testing convenience |

### Global Process/Singleton

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| `:ingestion_provider_browser_test_pid` | Provider setup and tests set it to `self()` | In-file bridge stubs send observation messages to that PID | The asserting test process | Stub observation messages can be delivered to the wrong test process | Yes | Testing convenience |
| `Zaq.Engine.Telemetry.Buffer` | `DataCase.setup_sandbox/1` allows and flushes globally named buffer if running | `DataCase` support code | Test sandbox owner plus the singleton buffer | A global buffer can need DB access owned by a test process | Already handled by `DataCase`; residual singleton coupling remains | True production singleton |
| `Zaq.Engine.EventRegistry` | `DataCase.isolate_event_registry/0` unregisters/restores globally named process | Workflow/event sync code outside this test's direct focus | Tests that need registry sync; otherwise inert | Concurrent tests can race while unregistering/restoring a singleton | Partly handled defensively | True production singleton; test isolation workaround |

### Runtime Configuration

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| `Application env :zaq, Zaq.Storage` | Common setup and volume/delete tests set `[base_path: tmp_dir, volumes: ...]` | `Zaq.Storage.FileExplorer.storage_config/1` via `Zaq.Config.get(:zaq, Zaq.Storage, [], opts)` | ChannelConfig-derived storage opts or the test request/view | One test's base path/volumes can make another test read, write, rename, or delete the wrong files | Mostly yes | Production runtime global |
| `Application env :zaq, Zaq.Ingestion` | Common setup and cleanup tests set `[base_path: tmp_dir, volumes: ...]` | `Zaq.Ingestion.DocumentProcessor` config helpers use `Application.get_env(:zaq, Zaq.Ingestion, [])` | Ingestion request/job/processor opts where behavior varies | Processor limits/timeouts/storage assumptions can change under another test | Partly | Production runtime global |
| `:ingestion_prep_ttl_ms` | Prep progress tests set it to `0` | `IngestionLive.prep_ttl_ms/0` | The mounted LiveView instance | One test can force another LiveView's progress TTL to zero | Yes | Testing convenience around production default |
| `system.global.base_url` | Watch tests call `Zaq.System.set_global_base_url/1` | `Zaq.Channels.WebhookUrl.build/2`; `IngestionLive.global_base_url_present?/0`; `IngestionLive.watch_disabled_reason/1` | Production singleton; in tests, the scenario or explicit config seam | Watch enabled/disabled state and webhook URL depend on whichever test last wrote the row | Harder, but possible with a production-meaningful config seam | True production-global |
| Embedding config rows | Common setup calls `SystemConfigFixtures.seed_embedding_config/1` | `Zaq.System.get_llm_config/0` and `Zaq.System.embedding_ready?/0` influence LiveView assign state | Test database sandbox owner | Config keys are singleton rows; concurrent writes can conflict or alter visible config if sandbox ownership/shared behavior changes | Maybe, with config seam or isolated fixture strategy | Production-global settings |

### PubSub/Shared Topic

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| `"ingestion:jobs"` on `Zaq.PubSub` | Production broadcasts through `JobLifecycle`; tests mostly send directly to `view.pid` | `IngestionLive.mount/3` subscribes connected views; `Ingestion.subscribe/0` subscribes callers | Production ingestion job monitor topic | Any real broadcast reaches every connected ingestion LiveView; filtering by job/status must be perfect for async isolation | Topic scoping is possible but needs design care | True production-global |

### Filesystem

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| Per-test `tmp_dir` under `System.tmp_dir!()` | Common setup creates files; many tests create/rename/delete files; `on_exit` removes directory | `Zaq.Storage`, `Zaq.Storage.FileExplorer`, direct assertions | The test process and its mounted LiveView | Unique dirs are safe, but global `Zaq.Storage` selection is not; another test can point storage operations at the wrong root | Yes | Filesystem is real; selected root should be test-owned |

### Database/Sandbox Ownership

| Resource/key/module | Test writes or mutates | Production or stub reads | Ideal owner | Violated concurrent invariant | Test-local possible? | Production-global or testing convenience? |
| --- | --- | --- | --- | --- | --- | --- |
| User `username: "ingestion_live_admin"` | Common setup overrides `super_admin_fixture/1` default unique username | Accounts unique constraint on `users.username` | Individual test | Concurrent inserts can block or conflict on a unique username | Yes | Testing artifact |
| `channel_configs.provider = "disk"` | Common setup inserts enabled disk config in every test | `ChannelConfig.get/list` paths, `DataSourceBridge`, `Storage.disk_config_opts/2`; unique index on provider | Individual test or shared fixture with test-local ownership | Concurrent inserts for provider `disk` can conflict because `channel_configs.provider` is unique | Yes, by fixture strategy or scoped test setup | Production uniqueness invariant; test artifact |
| Provider configs such as `google_drive` | Provider setup inserts configs with unique provider names unless helper varies provider | `IngestionLive` provider resolution and `DataSourceBridge` | Individual test | Reusing the same provider under a unique provider index can conflict | Partly; provider identity is semantically global | Production uniqueness invariant |
| Documents by `source` | Many tests create `Document` rows with repeated source strings | `Document.get_by_source/1`; ingestion status maps; permission queries | Individual test database sandbox | Async database sandbox usually isolates, but unique source collisions can still block/conflict depending transaction overlap | Use unique config IDs/sources | Production uniqueness invariant |
| `storage_entries(volume, relative_path)` | `EntryCatalog.ensure/3` in helper paths and production listing | `EntryCatalog`, `Storage` listing/source identity | Individual test database sandbox and volume namespace | Same volume/path identities can collide if sandbox ownership is not isolated | Mostly yes | Production uniqueness invariant |

### Not Found In The In-File Stubs

I did not find process registration, ETS, `persistent_term`, PubSub subscribe/broadcast, OS environment mutation, or filesystem mutation in `ProviderBrowserBridgeStub`, `ProviderBrowserErrorBridgeStub`, `ProviderBrowserCustomBridgeStub`, `IngestionCallStub`, `CreateDocumentStub`, or `IngestionRouterStub`.

The in-file stubs do read global `Application` env and send to a globally configured PID. That is enough to make them unsafe under async execution.

## C. Highest-Leverage Root Causes

1. Dependency selection is read from global `Application` env during LiveView events, not captured per mounted LiveView/request.
2. Stub behavior is controlled by the same global store as dependency selection.
3. Disk storage root/volume config is VM-wide, while tests expect each `tmp_dir` to be private.
4. Watch behavior depends on the database singleton global base URL.
5. The LiveView subscribes to a production-wide PubSub topic, so any real ingestion broadcast is shared across mounted views.

## D. Ownership Map

| Major dependency/state | Current owner | Correct owner |
| --- | --- | --- |
| `:ingestion_data_source_bridge_module` | Whole VM application env | Mounted LiveView/event opts/request |
| `:ingestion_call_module` | Whole VM application env | Mounted LiveView or explicit routed call opts |
| `:ingestion_create_document_module` | Whole VM application env | Create-document action boundary |
| `:ingestion_node_router_module` | Whole VM application env | Event dispatch boundary |
| `provider_browser_*` responses | Whole VM application env | Owning test process/fake instance |
| `:ingestion_provider_browser_test_pid` | Whole VM application env | Asserting test process, passed through fake ownership |
| `:ingestion_call_responses` | Whole VM application env | Owning test process/fake instance |
| `:ingestion_create_document_response` | Whole VM application env | Owning test process/fake instance |
| `:ingestion_router_response` | Whole VM application env | Owning test process/fake instance |
| `Zaq.Storage` config | Whole VM application env | ChannelConfig-derived storage opts or per-test request/view opts |
| `Zaq.Ingestion` config | Whole VM application env | Ingestion request/job/processor opts where behavior varies |
| `:ingestion_prep_ttl_ms` | Whole VM application env | Mounted LiveView config |
| `system.global.base_url` | Singleton database row | Production singleton; tests need explicit scenario ownership or a production-meaningful reader seam |
| `"ingestion:jobs"` PubSub topic | Production-wide topic | Production-wide topic with strict filtering, or test-scoped subscription only when testing messages |
| Per-test temp files | Test process, but selected by global config | Test process plus test-owned storage config |
| Fixed usernames and provider rows | Module setup/test fixture | Individual test with unique values |

## E. Recommended Refactor Order

1. Separate dependency selection from fake behavior. Keep production defaults, but make `IngestionLive` capture injectable modules from opts/session/config once per test-owned view instead of rereading globals.
2. Replace in-file app-env stubs with per-test owned fakes or Mox-style expectations. The bridge fake should own its responses and observer PID locally.
3. Thread storage configuration through existing `Zaq.Config`/opts paths for LiveView-triggered storage operations. Avoid `Zaq.Config.get(..., [])` fallback where tests need ownership, because `Zaq.Config.get(..., [])` still falls back to global `Application` config.
4. Give prep TTL a LiveView-owned config path instead of `Application.get_env/3`.
5. Address global base URL tests last. This is closest to a true production-global invariant, so either isolate those tests in a small `async: false` module or add a production-meaningful config reader seam.
6. Make setup fixtures unique: do not override `super_admin_fixture/1` with a fixed username, and avoid repeated unique `channel_configs.provider = "disk"` collisions in async groups.

## F. Async Readiness

After steps 1 and 2, provider browsing, provider CRUD response, permission round-trip, router degradation, and create-document error tests can likely move to async.

After step 3, disk browsing, upload, rename, move, delete, volume-selection, stale detection, and share-modal filesystem tests can likely move to async, assuming per-test unique fixtures.

After step 4, prep progress TTL tests can move to async.

After step 5, most watch tests can move to async except any test intentionally proving the real global base URL behavior.

After step 6, remaining database fixture collisions should be removed; `ConnCase` and SQL sandboxing can then isolate database state for the async-safe groups.

The target invariant should remain: every async test owns all mutable state that determines its behavior.
