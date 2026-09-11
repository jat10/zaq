# IngestionLive Mental Model

Date: 2026-09-08

Scope:

- `lib/zaq_web/live/bo/ai/ingestion_live.ex`
- Directly related production modules called by the LiveView
- Coverage references from `test/zaq_web/live/bo/ai/ingestion_live_test.exs`

Constraint: understanding current behavior only. No refactor recommendations and no async recommendations.

## High-Level Model

`ZaqWeb.Live.BO.AI.IngestionLive` is the BO file/data-source browser for ingestion. It owns UI state, user interaction handling, modal state, selected rows, job drawer state, provider folder navigation state, transient preparation-progress state, and permission/watch modal state.

It does not directly implement provider APIs. Provider actions flow through `%Zaq.Event{}` and `NodeRouter` into Channels or Ingestion boundaries. It does directly read some database-backed context functions for rendering enrichment, such as document status and permission counts.

The page is provider-neutral. Disk is represented as a data-source provider through `Zaq.Channels.DiskBridge`; remote providers such as Google Drive use `Zaq.Channels.DataSourceBridge` and provider bridges. The LiveView mostly treats both as `Zaq.Contracts.Record` values.

## Major Responsibilities

### Mount / Initial Loading

1. Trigger: LiveView lifecycle `mount/3`.
2. Handler: `mount(params, _session, socket)`.
3. Collaborators:
   - `Phoenix.PubSub.subscribe/2`
   - `ChannelConfig` + `Repo`
   - `DataSourceBrowser`
   - `NodeRouter`
   - `Zaq.System`
   - `People`
   - `IngestionLive.load_jobs/1`
   - `IngestionLive.load_entries/1`
4. Collaborator responsibilities:
   - PubSub subscribes connected views to `"ingestion:jobs"`.
   - `ChannelConfig`/`Repo` discover enabled data-source configs.
   - `DataSourceBrowser.source/2` normalizes source-scope navigation state.
   - `NodeRouter` routes source-scope and capability events.
   - `Zaq.System.embedding_ready?/0` tells UI whether embedding is ready.
   - `People.list_people/0` and `People.list_teams/0` populate share-target choices.
5. Result:
   - Source scopes, active source, provider, provider config id, capabilities, jobs, entries, upload config, and modal defaults.
6. Socket/UI changes:
   - Assigns initial source/navigation state.
   - Loads jobs and entries.
   - Enables LiveView uploads with accepted extensions.
   - Shows empty state when no data source is enabled.
7. Failure paths:
   - Capability snapshot failures resolve to empty capabilities.
   - Missing provider config assigns provider error.
   - Non-list job responses become an empty job list.
8. Tests:
   - `does not dispatch when no enabled provider configuration exists`
   - `provider watch_supported disables browsing and watching when capability snapshot raises`
   - `does not fall back to storage when disk configuration is missing`
   - `shows data source setup guidance when no data source is enabled`
   - `shows enabled data source scopes as source buttons`
   - `non-list jobs response leaves the jobs list empty`

### Provider Browsing / Listing

1. Trigger: mount, navigation, source switch remount, refresh after mutations/jobs.
2. Handler: `load_entries/1`, `load_provider_entries/1`, `dispatch_list_files/3`.
3. Collaborators:
   - `DataSourceEvents.build_and_dispatch/4`
   - `NodeRouter`
   - `Zaq.Channels.Api`
   - `Zaq.Channels.DataSourceBridge`
   - Provider bridge module selected by `data_source_bridge_module/0`
   - `Document`, `Ingestion`, `Permissions`
4. Collaborator responsibilities:
   - `DataSourceEvents` builds trusted BO channel events with actor and `skip_permissions`.
   - `Channels.Api` handles `:data_source_list_files` and calls bridge `list_files/3`.
   - Provider bridge returns a `RecordPage`.
   - `Document.list_by_sources/1`, `Ingestion.count_document_permissions/1`, and watch helpers enrich status.
5. Result:
   - `{:ok, %RecordPage{records: records, pagination: ...}}`, `{:error, reason}`, or unexpected value.
6. Socket/UI changes:
   - Success assigns `entries`, `records_by_path`, `ingestion_map`, `provider_page`, `provider_page_token`, clears `provider_error`.
   - Error clears entries/maps and sets provider error text.
   - Unsupported list capability shows "This data source does not support browsing."
7. Failure paths:
   - No provider config.
   - Bridge returns `{:error, reason}`.
   - Bridge returns malformed/unexpected response.
   - Capability snapshot says listing unsupported or raises.
8. Tests:
   - `lists provider records from the route provider and navigates folders`
   - `provider browsing dispatches root and nested shared filters distinctly`
   - `provider load errors render empty state and detailed provider_error`
   - `provider capability guards only block unsupported actions`
   - `uses any enabled provider from the URL without an ingestion allowlist`
   - `provider record is stale when source modified_at is newer than document updated_at`

### File / Folder Navigation

1. Trigger: `"navigate"`, `"go_back"`, `"switch_source"`, move-modal navigation.
2. Handler:
   - `handle_event("navigate", ...)`
   - `handle_event("go_back", ...)`
   - `navigate_provider/2`
   - `provider_go_back/1`
   - `handle_event("switch_source", ...)`
   - `move_navigate`, `move_go_back`
3. Collaborators:
   - `DataSourceBrowser`
   - Provider listing path through `dispatch_list_files/3`
   - `push_navigate/2`
4. Collaborator responsibilities:
   - `DataSourceBrowser` normalizes source IDs and destination params.
   - Provider bridge lists folders/children for current parent.
   - Phoenix navigation remounts with `provider`, `config_id`, and `scope_id`.
5. Result:
   - Updated provider folder stack and record listing.
6. Socket/UI changes:
   - `current_dir`, `breadcrumbs`, `provider_folder_stack`, and `selected` are reset or advanced.
   - Move modal maintains separate `move_current_dir`, `move_breadcrumbs`, and `move_folders`.
7. Failure paths:
   - Missing breadcrumb/folder id leaves socket unchanged.
   - Move-folder list errors produce empty move options.
   - Unknown source ID leaves socket unchanged.
8. Tests:
   - `navigates directories and handles non-directory navigation`
   - `provider root navigation and go_back reset the breadcrumb stack`
   - `provider breadcrumb navigation updates the stack and ignores missing ids`
   - `provider go_back from nested folder returns to parent folder`
   - `scoped provider roots preserve opaque child ids through navigation and creation`
   - `switch_source navigates to a data source provider`
   - `switch_source changes disk scope and loads entries`
   - `switch_source resets current_dir to root`
   - `move_go_back from root dir '.' stays at root`
   - `move_navigate to an invalid folder clears move folder options`

### Selection And View Mode

1. Trigger: `"toggle_select"`, `"select_all"`, `"toggle_view_mode"`.
2. Handler:
   - `handle_event("toggle_select", ...)`
   - `handle_event("select_all", ...)`
   - `handle_event("toggle_view_mode", ...)`
3. Collaborators:
   - `IngestionFileStatus.record_path/1`
   - UI components.
4. Collaborator responsibilities:
   - Extract stable record path/id/name used by UI selection.
5. Result:
   - New `MapSet` of selected item paths or new view mode.
6. Socket/UI changes:
   - Bulk action counts update.
   - List/grid rendering switches.
7. Failure paths:
   - Invalid view modes are not matched by the guarded clause.
8. Tests:
   - `supports selection, modal open/close, and view mode toggle`
   - `lists provider records from the route provider and navigates folders`

### Uploads

1. Trigger:
   - `"show_upload_modal"`
   - LiveView upload validation/cancel/submit events.
2. Handler:
   - `handle_event("show_upload_modal", ...)`
   - `handle_event("validate_upload", ...)`
   - `handle_event("cancel_upload", ...)`
   - `handle_event("upload", ...)`
   - `upload_entry/3`
3. Collaborators:
   - Phoenix LiveView upload APIs.
   - `EncodeBase64`
   - `CreateDocument`
   - `DataSourceTool`
   - Channels data-source create event.
4. Collaborator responsibilities:
   - Phoenix stages uploaded temp files.
   - `EncodeBase64.run/2` encodes bytes for data-source transport.
   - `CreateDocument.run/2` decodes and dispatches `:data_source_create_file`.
   - Provider/storage bridge persists remote/disk document.
5. Result:
   - Per file: `{:ok, path}` or `{:error, reason}`.
6. Socket/UI changes:
   - On all uploads complete: reload entries, set flash, push `"folder_batch_done"`, maybe close modal.
   - If entries are still in progress: socket unchanged.
   - `folder_drop_skipped` is cleared on actual upload.
7. Failure paths:
   - Incomplete upload does nothing.
   - Encode/create errors are collected as failed uploads.
   - Mixed success keeps modal open.
   - Unsupported create capability shows info flash.
8. Tests:
   - `uploads accepted files`
   - `closes upload modal after all files upload successfully`
   - `uploads mixed valid and invalid files while keeping the modal open`
   - `submitting the upload form with no entries leaves the modal open`
   - `duplicate upload uses OS-style deduplication`
   - `uploads png and jpg files`
   - `provider upload routes decoded content through create document action`
   - `provider create without a record falls back to the uploaded filename`
   - `validate_upload event does not crash the view`
   - `cancel_upload removes a queued upload entry`
   - `upload errors do not escape the tmp dir and keep the view alive`
   - `does not crash when entries are still in-progress (upload fired before transfer completes)`
   - `pushes folder_batch_done event after successful upload`
   - `uses client_relative_path as dest when set`
   - `falls back to client_name when client_relative_path is empty string`
   - `falls back to client_name when client_relative_path is nil`

### Create Document / Raw Content / New Folder

1. Trigger:
   - `"show_new_folder_modal"`
   - `"create_folder"`
   - `"show_add_raw_modal"`
   - `"save_raw_content"`
   - `"add_raw_content"`
2. Handler:
   - Modal handlers above.
   - Shared `create_document/2`.
3. Collaborators:
   - `CreateDocument`
   - `DataSourceBrowser.destination_params/2`
   - `BOActor`
   - Channels data-source create event.
4. Collaborator responsibilities:
   - Build destination from active source and provider folder stack.
   - Create provider/disk file/folder through Channels.
5. Result:
   - `{:ok, result}` or `{:error, reason}`.
6. Socket/UI changes:
   - Success closes modal, reloads entries, sometimes reloads jobs, shows flash.
   - Raw filename extension is normalized to `.md` when absent.
7. Failure paths:
   - Blank folder name.
   - Blank raw filename/content.
   - Provider/storage create error.
   - Nonbinary action errors formatted through `create_modal_error/2`.
   - Unsupported create capability.
8. Tests:
   - `creates folders with validation and error handling`
   - `provider new folder routes through create document action`
   - `shows creation CTAs when provider create_item is supported`
   - `show_add_raw_modal opens the modal`
   - `save_raw_content with blank filename shows error`
   - `save_raw_content with blank content shows error`
   - `save_raw_content creates file without extension and auto-appends .md`
   - `save_raw_content preserves existing extension`
   - `add_raw_content alias behaves identically to save_raw_content`
   - `provider raw markdown routes through create document action`
   - `provider creation errors are inspected in the open raw-content modal`
   - `save_raw_content reports a nonbinary action error`
   - `creates in the current provider folder and preserves breadcrumbs`

### Rename / Move / Delete

1. Trigger:
   - `"rename_item"`, `"confirm_rename"`
   - `"move_item"`, `"move_navigate"`, `"move_go_back"`, `"confirm_move"`
   - `"delete_item"`, `"confirm_delete"`
   - `"show_delete_confirmation"`, `"confirm_delete_selected"`
2. Handler:
   - `do_rename/4`
   - `do_move/5`
   - `delete_data_source_path/2`
   - `dispatch_data_source_update/3`
   - `dispatch_data_source_delete/2`
   - `dispatch_data_source_removed/1`
3. Collaborators:
   - `DataSourceEvents`
   - `Channels.Api`
   - `DataSourceBridge` or disk/provider bridge
   - `Zaq.Ingestion.process_data_source_changes/1` via `NodeRouter` after delete success.
4. Collaborator responsibilities:
   - Channels performs provider/storage mutation.
   - Ingestion receives a removed-record signal to clean indexed documents/chunks.
5. Result:
   - Update/delete returns `:ok`, `{:ok, result}`, or `{:error, reason}`.
6. Socket/UI changes:
   - Success closes modal, clears selection, reloads entries, shows flash.
   - Bulk delete shows success or partial-failure flash.
   - Move modal loads folder options.
7. Failure paths:
   - Blank rename.
   - Rename to same name closes modal.
   - Path traversal/update errors.
   - Missing delete record.
   - Delete unsupported by capabilities.
   - Move unsupported, already in same folder, moving folder into itself, listing move folders fails.
8. Tests:
   - `provider rename modal uses the record name instead of the provider id`
   - `renames files and handles validation branches`
   - `deletes files and directories with success and failure cases`
   - `removes document and chunks in non-volume mode`
   - `removes volume-prefixed document and chunks`
   - `deleting nested directory removes nested documents and chunks in volume mode`
   - `bulk delete handles full success and partial failures`
   - `bridge-backed provider deletion accepts plain ok and refreshes`
   - `moves items and handles move validation branches`
   - `provider move folder browser keeps the selected config`
   - `confirm_move shows an error when source is missing`

### Ingestion Job Creation / Listing / Retry / Cancel

1. Trigger:
   - `"ingest_selected"`
   - `"set_mode"`
   - `"open_jobs_drawer"`, `"close_jobs_drawer"`
   - `"filter_status"`
   - `"retry_job"`, `"cancel_job"`
2. Handler:
   - `dispatch_ingest_records/3`
   - `ingestion_call/2`
   - `load_jobs/1`
   - `put_ingest_result_flash/2`
3. Collaborators:
   - `NodeRouter.invoke/4` for `list_jobs`, `retry_job`, `cancel_job`.
   - `NodeRouter.dispatch/1` for `:ingest_records`.
   - `Zaq.Ingestion`.
   - `DocumentProcessor` indirectly through ingestion workers or inline mode.
4. Collaborator responsibilities:
   - `Ingestion.ingest_records/2` creates ingestion jobs from canonical records.
   - `Ingestion.list_jobs/1` returns recent jobs.
   - `retry_job/1` requeues failed/completed-with-errors jobs.
   - `cancel_job/1` stops pending/processing jobs and marks failure/cancellation state.
5. Result:
   - Ingest: `{:ok, jobs}`, partial failure, or error.
   - Job list: list or non-list.
   - Retry/cancel: `{:ok, job}` or `{:error, reason}`.
6. Socket/UI changes:
   - Ingest clears selection, reloads jobs/entries, opens drawer, sets ingest toast or flash.
   - Filter changes `status_filter` and reloads jobs.
   - Retry/cancel reload jobs and shows flash.
7. Failure paths:
   - Unsupported download capability.
   - Empty selected records returns ok with no jobs.
   - Partial failure with no jobs shows error flash.
   - Partial failure with some jobs shows toast.
   - Unexpected router response shows generic failure.
   - Non-list job response becomes empty jobs.
   - Retry/cancel errors show error flash.
8. Tests:
   - `hides mode controls while set_mode still accepts inline`
   - `ingest_selected clears selection and shows flash for a file`
   - `ingest_selected clears selection and shows flash for a directory`
   - `ingest_selected processes file without role_id (RBAC-based access)`
   - `ingest_selected reports an error flash when all selected records fail`
   - `ingest_selected reports a warning flash when some records fail`
   - `ingest_selected skips missing selected paths`
   - `ingest_selected clears selection on an unexpected router response`
   - `dismiss_ingest_toast clears a successful ingestion toast`
   - `opens and closes the jobs drawer from the monitor jobs button`
   - `filters jobs, handles retry/cancel branches, and refreshes on job updates`
   - `retry_job and cancel_job return not_found for missing ids`
   - `filtering by 'all' shows jobs of every status`
   - `filter_status with unknown value returns empty job list`
   - `others job filter includes active non-terminal statuses`
   - `shows chunk progress and retry button for completed_with_errors jobs`
   - `non-list jobs response leaves the jobs list empty`

### Permissions / Share Flows

1. Trigger:
   - `"share_item"`
   - `"view_provider_permissions"`
   - `"toggle_public"`
   - `"add_permission_target"`
   - `"toggle_permission_right"`
   - `"remove_pending"`
   - `"remove_permission"`
   - `"confirm_share"`
   - `"provider_permissions_info"`
2. Handler:
   - `open_source_share_modal/3`
   - `source_permissions/2`
   - `dispatch_source_permission_sync/2`
   - modal state handlers.
3. Collaborators:
   - `People`
   - `Permissions`
   - `StorageEntry`
   - `Ingestion`
   - `Document`
   - `DataSourceEvents`
   - `NodeRouter`
   - Provider bridge list/replace permissions.
4. Collaborator responsibilities:
   - `People` supplies share targets.
   - `Permissions` checks public access and grants/removes ACLs.
   - Provider bridge returns provider permission records.
   - `Ingestion.sync_data_source_permissions/3` replaces source permissions and syncs document permissions.
5. Result:
   - Modal permissions list, public state, inherited-public state, save success, or error.
6. Socket/UI changes:
   - Opens editable share modal for source records.
   - Opens read-only imported-permissions modal for provider-ingested docs.
   - Pending target list and options update as targets are added/removed.
   - Save success closes modal, reloads entries, shows flash.
   - Save failure keeps modal open with error.
7. Failure paths:
   - Read-only modal ignores mutations.
   - Inherited public toggle is ignored.
   - Invalid target ignored.
   - Missing provider source id.
   - Provider permissions unavailable.
   - Permission sync failure.
8. Tests:
   - `share_item opens the share modal for a file`
   - `folder share CTA carries the directory discriminator`
   - `add_permission_target with a person appends to pending`
   - `add_permission_target with a team appends to pending`
   - `toggle_permission_right adds a right to a pending entry`
   - `confirm_share persists permissions to the database`
   - `remove_permission deletes an existing permission`
   - `duplicate add_permission_target is ignored`
   - `duplicate pending share target keeps the existing pending entry unchanged`
   - `remove_pending removes an entry from share_modal_pending`
   - `add_permission_target with invalid value is a no-op`
   - `remove_permission for folder deletes across all docs`
   - `confirm_share for folder persists permissions to all docs`
   - `share modal shows Public access toggle`
   - `toggling public and confirming saves public ACLs`
   - `toggling public twice and confirming leaves the tag unchanged`
   - `toggling public off removes public ACL from an already public document`
   - `toggle without confirm does not persist`
   - `toggling folder public and confirming saves public ACLs for descendants`
   - `toggling folder public twice and confirming leaves flag unchanged`
   - `toggling folder public off removes public ACLs`
   - `cannot toggle public access inherited from a parent`
   - `keeps direct person and team grants while dropping inherited and unknown records`
   - `provider folder permissions report unavailable responses`
   - `confirm_share keeps the modal open when provider permissions fail`
   - `provider share reports a blank source id and permission failures`
   - `shows provider document with data-source permissions guidance`
   - `provider read-only share modal events are no-ops`
   - `provider_permissions_info explains provider-managed permissions`

### Watch / Unwatch

1. Trigger:
   - `"toggle_watch_status"`
   - `"watch_selected"`
   - `"unwatch_selected"`
   - `"retry_watch"`
2. Handler:
   - `watch_target_for_path/2`
   - `apply_watch_update/4`
   - `request_provider_watches/2`
   - `clear_provider_watches/2`
   - `dispatch_provider_watch/2`
   - `dispatch_provider_unwatch/1`
3. Collaborators:
   - `Ingestion.request_watch/1`
   - `Ingestion.clear_watch/1`
   - `Ingestion.mark_watch_active/2`
   - `Ingestion.mark_watch_error/2`
   - `Ingestion.count_watched_provider_documents/2`
   - `ChannelEvents`
   - provider bridge `watch_item/2`, `unwatch_item/2`
   - `WebhookUrl`
   - `Zaq.System.get_global_base_url/0`
4. Collaborator responsibilities:
   - Ingestion persists local document watch status.
   - Channels/provider bridge sets up or tears down provider-side watch.
   - `WebhookUrl` builds public callback URL from global base URL.
5. Result:
   - Watch request/clear produces `%{updated: n, skipped: n}`.
   - Provider watch returns `{:ok, result}`, `{:error, reason}`, or unexpected value normalized to error.
6. Socket/UI changes:
   - Reloads entries after watch change.
   - Clears selection for bulk operations.
   - Shows info flash for changed/skipped/no-op outcomes.
   - Error-status click opens watch-error modal.
7. Failure paths:
   - Watch unsupported by capability.
   - Global base URL missing.
   - File not ingested.
   - Watch inherited from parent.
   - Provider watch error marks document error.
   - Mark-active failure counts as skipped.
   - Provider unwatch error/unexpected response counts as skipped after local clear.
8. Tests:
   - `disables provider watch when global base URL is not configured`
   - `provider watch uses global base URL for webhook address`
   - `provider folder can be watched before a folder document exists`
   - `provider folder watch is shown as inherited on child items`
   - `provider watch on an inherited child shows a skip flash`
   - `provider watch_supported recognizes tuple and map capability snapshots`
   - `provider watch skips unsupported providers without a watch_changes_webhook capability`
   - `provider watch_selected reuses the provider watcher after the first dispatch`
   - `provider watch_selected surfaces provider errors and marks the document errored`
   - `provider unwatch_selected dispatches teardown when the last watched item is cleared`
   - `provider unwatch_selected also accepts a plain :ok bridge response`
   - `provider unwatch_selected treats bridge errors as skipped work`
   - `provider unwatch_selected treats unexpected bridge responses as skipped work`
   - `toggle_watch_status ignores unsupported disk watches and clears existing watches`
   - `errored watch click opens details modal and retry requests watch`
   - `watch_selected skips disk selections when watch capability is not advertised`
   - `retry_watch without an open modal just clears modal state`
   - `watch_selected with no eligible selected records shows a no-op flash`
   - `unwatch_selected clears selected watched records and skips non-clearable selections`
   - `toggle_watch_status falls back to the default watch error message`
   - `toggle_watch_status on a non-ingested disk data-source file shows watch setup guidance`
   - `provider watch degrades when marking active fails`
   - `unexpected provider watch response leaves status unchanged`

### Previews

1. Trigger:
   - `"open_preview"`
   - `"close_preview_modal"`
2. Handler:
   - `preview_record/2`
   - `open_record_preview/3`
   - `open_provider_preview/2`
   - `PreviewHelpers.open_preview/3`
   - `PreviewHelpers.close_preview/2`
3. Collaborators:
   - `PreviewHelpers`
   - `FilePreviewData`
   - Provider record `url`
   - Materialization handle in `Record`
4. Collaborator responsibilities:
   - Provider URL previews create external iframe/open-link modal data.
   - `PreviewHelpers` loads local/materialized preview data and handles authorization/previewability.
5. Result:
   - Preview assign or flash error.
6. Socket/UI changes:
   - Success sets `preview` and `modal: :preview`.
   - Close clears preview/modal.
   - Optional filename override updates preview filename when nonblank.
7. Failure paths:
   - Missing provider record.
   - Provider record with no URL/materialization handle.
   - Non-previewable file type.
   - Unauthorized preview.
   - Malformed path.
8. Tests:
   - `previews provider records by URL and queues external ingestion`
   - `provider preview errors when a record has no URL`
   - `provider preview does not fall back to local preview for missing records`
   - `provider preview with filename still errors for missing provider record`
   - `provider preview events distinguish URL, unavailable, missing, and malformed paths`
   - `opens file preview inside modal`
   - `opens preview from a disk ChannelConfig volume whose path differs from its name`
   - `disk data-source preview ignores blank filename override`
   - `file_url/1` tests cover URL formatting helper behavior.

### Storage / Filesystem Interaction

1. Trigger:
   - Disk-backed listing, create, upload, rename, move, delete, preview.
2. Handler:
   - Same LiveView handlers as provider browsing/create/update/delete/preview.
3. Collaborators:
   - `Zaq.Channels.DiskBridge`
   - `Zaq.Storage`
   - `Zaq.Storage.FileExplorer`
   - `Zaq.Storage.EntryCatalog`
   - `Zaq.Storage.VolumeConfig`
   - `Permissions`
4. Collaborator responsibilities:
   - DiskBridge maps Storage entries to canonical `Record`s.
   - Storage owns mounted-volume filesystem operations and authorization.
   - EntryCatalog gives stable file/folder identities.
   - VolumeConfig derives storage roots from disk ChannelConfig settings.
5. Result:
   - Disk files/folders are returned as data-source records; filesystem mutations return ok/error.
6. Socket/UI changes:
   - Listings render disk records.
   - Mutations reload entries and update badges.
   - Status enrichment shows ingested/stale/failed/shared/public/watch state.
7. Failure paths:
   - Missing storage entry.
   - Path traversal.
   - Unknown volume.
   - Non-directory navigation.
   - Source ACL inherited public state.
8. Tests:
   - Disk navigation, upload, raw content, rename, move, delete tests.
   - `disk tabs come from disk source scopes instead of storage fallback`
   - `files in the selected volume are listed after switching`
   - `create CTAs write into the selected nested non-default volume`
   - `list view shows source ACL sharing for an un-ingested file`
   - `list view shows public source ACL without counting Everyone as shared`
   - `folder inherits public source ACL display from parent`
   - Markdown record-selection tests for PDF/image adjacent markdown behavior.

### PubSub / Job Progress Updates

1. Trigger:
   - Production PubSub messages on `"ingestion:jobs"`.
   - Tests send messages directly to `view.pid`.
   - Internal prune timer sends `:prune_prep_progress`.
2. Handler:
   - `handle_info({:job_updated, job}, socket)`
   - `handle_info({:job_progress, job_id, payload}, socket)`
   - `handle_info(:prune_prep_progress, socket)`
3. Collaborators:
   - `Phoenix.PubSub`
   - `Zaq.Ingestion.JobLifecycle`
   - `IngestJob`
   - `Process.send_after/3`
4. Collaborator responsibilities:
   - JobLifecycle broadcasts persisted job updates and transient prep progress.
   - LiveView merges updates into local job list and transient progress map.
5. Result:
   - Job update struct, progress payload map, or prune tick.
6. Socket/UI changes:
   - Merges, updates, removes, or caps jobs at 20.
   - Recomputes `active_prep_ids`.
   - Clears prep progress when chunks are scheduled or job finishes/retries.
   - Records prep progress only for active prep jobs.
   - Reloads entries on terminal statuses and when chunk scheduling starts.
7. Failure paths:
   - Malformed `job_updated` ignored.
   - Progress for inactive job ignored.
   - Stale prep entries pruned after TTL.
8. Tests:
   - `refreshes entries when job transitions to processing with chunks scheduled`
   - `job_updated for a job not matching the current filter is silently ignored`
   - `job_updated removes an existing row when it stops matching the current filter`
   - `job_updated ignores malformed payloads`
   - `others filter removes a job once it stops matching`
   - `job_updated updates existing rows and caps the list at 20 entries`
   - `renders a Preparing indicator for a processing job with no chunks yet`
   - `clears the prep indicator once chunks are scheduled`
   - `drops prep progress when the job completes`
   - `drops prep progress when the job is sent back to pending for retry`
   - `ignores a straggler progress message that arrives after the job finished`
   - `prunes a stale prep entry left by an orphaned job after the TTL`
   - `keeps a fresh prep entry that is still within the TTL`
   - `prune removes stale prep entries and keeps fresh ones queued for another sweep`

### Folder Drop Support

1. Trigger:
   - Client hook sends `"folder_drop_skipped"`.
   - Upload handler sends `"folder_batch_done"` after successful complete upload handling.
2. Handler:
   - `handle_event("folder_drop_skipped", ...)`
   - `handle_event("upload", ...)`
3. Collaborators:
   - LiveView client upload/dropzone components.
4. Collaborator responsibilities:
   - Client reports unsupported skipped files.
   - Server keeps skipped-file UI state.
5. Result:
   - Skipped list assign or unchanged socket.
6. Socket/UI changes:
   - Valid skipped list displays skipped-file area in upload modal.
   - Malformed payload leaves previous skipped list intact.
7. Failure paths:
   - Non-list skipped payload ignored.
8. Tests:
   - `assigns skipped list when payload contains a valid list`
   - `assigns empty list when payload contains an empty list`
   - `does not crash and leaves socket unchanged when payload is malformed`
   - `does not clear folder_drop_skipped across batches`

## A. Responsibility Map

| IngestionLive responsibility | Collaborator | Contract |
| --- | --- | --- |
| Initial data-source discovery | `ChannelConfig`, `Repo` | Query enabled `kind == "data_source"` configs |
| Source-scope normalization | `DataSourceBrowser` | Convert config/scope into navigation source maps |
| Channel event construction | `DataSourceEvents` | Build trusted BO `%Zaq.Event{}` with actor and event opts |
| Cross-service dispatch | `NodeRouter` | Dispatch/invoke role-boundary calls |
| Provider/disk listing | `Channels.Api` + `DataSourceBridge` | `list_files(provider, params, trusted_context) -> {:ok, RecordPage} | {:error, reason}` |
| Provider capabilities | `Channels.Api` + bridge module | `capability_snapshot(provider[, request]) -> {:ok, %{resolved: map}} | map | error` |
| Create file/folder/document | `CreateDocument` + `DataSourceTool` | Build data-source create request and normalize response/error |
| Ingestion jobs | `Zaq.Ingestion` | `ingest_records`, `list_jobs`, `retry_job`, `cancel_job` |
| Watch state | `Zaq.Ingestion` | Request/clear/mark/count watch document state |
| Provider watch transport | `ChannelEvents` + provider bridge | `watch_item`/`unwatch_item` provider operations |
| Webhook URL | `WebhookUrl`, `Zaq.System` | Build URL from global base URL |
| Document status enrichment | `Document`, `Ingestion`, `Permissions` | Load indexed docs, permission counts, public/watch status |
| Share targets | `People` | List people and teams |
| ACL persistence/sync | `Permissions`, `Ingestion.sync_data_source_permissions` | Persist source ACLs and mirror to documents |
| Disk filesystem | `DiskBridge`, `Storage`, `FileExplorer`, `EntryCatalog` | Mounted-volume list/create/update/delete/preview |
| Preview modal | `PreviewHelpers`, `FilePreviewData` | Load local/materialized previews or external URL previews |
| Rendering | `IngestionComponents`, design-system components | Render file browser, modals, jobs panel, badges |
| Job updates | `PubSub`, `JobLifecycle` | Receive `{:job_updated, job}` and `{:job_progress, id, payload}` |

## B. Event Flow Diagrams

### 1. Provider Page Initial Load

`user opens /bo/ingestion/google_drive -> mount/3 -> enabled_data_source_sources/0 -> ChannelConfig/Repo + dispatch_source_scopes/2 -> NodeRouter -> Channels.Api -> DataSourceBridge.list_source_scopes -> source scopes`

`mount/3 -> action_capabilities/2 -> dispatch_capability_snapshot/2 -> NodeRouter -> Channels.Api -> bridge.capability_snapshot -> resolved capabilities -> socket action_capabilities/watch_supported/create_item_supported`

`mount/3 -> load_jobs/1 + load_entries/1 -> Ingestion.list_jobs + DataSourceBridge.list_files -> jobs/RecordPage -> socket jobs/entries/ingestion_map -> rendered browser`

### 2. Navigate Provider Folder

`click folder -> handle_event("navigate") -> navigate_provider/2 -> update provider_folder_stack/current_dir/breadcrumbs -> load_entries/1 -> dispatch_list_files/3 -> DataSourceEvents -> NodeRouter -> Channels.Api -> bridge.list_files -> RecordPage -> entries/records_by_path/ingestion_map`

### 3. Upload File

`submit upload -> handle_event("upload") -> consume_uploaded_entries/3 -> upload_entry/3 -> File.read! -> EncodeBase64.run -> create_document/2 -> CreateDocument.run -> DataSourceTool.dispatch -> NodeRouter -> Channels.Api.data_source_create_file -> bridge.create_file -> {:ok, result} | {:error, reason} -> load_entries + flash + maybe close modal`

### 4. Ingest Selected Records

`select rows -> handle_event("ingest_selected") -> selected_records/1 -> dispatch_ingest_records/3 -> Event.new(..., :ingestion, action: :ingest_records) -> router.dispatch -> Zaq.Ingestion.ingest_records -> {:ok, jobs} | partial failure | error -> clear selected + load_jobs + load_entries + toast/flash`

### 5. Provider Watch Selected

`select rows -> handle_event("watch_selected") -> selected_watch_targets/2 -> apply_bulk_watch_update/4 -> request_provider_watches/2 -> ingestion_call(:request_watch) -> maybe dispatch_provider_watch/2 -> ChannelEvents -> NodeRouter -> Channels.Api -> bridge.watch_item -> ingestion_call(:mark_watch_active | :mark_watch_error) -> load_entries + flash`

## C. Dependency Classification

| Collaborator | Classification |
| --- | --- |
| `IngestionComponents` and design-system components | UI-only |
| `IngestionFileStatus` | UI-only/status rendering helper |
| `DataSourceBrowser` | UI/application helper for provider-neutral navigation |
| `PreviewHelpers` | UI/application helper |
| `FilePreviewData` | Application/context boundary plus storage/database reads |
| `People` | Application/context boundary; storage/database |
| `Permissions` | Application/context boundary; storage/database |
| `Document`, `IngestJob`, `Chunk` | Storage/database schema/context |
| `Ingestion` | Application/context boundary; storage/database; event/PubSub for jobs |
| `CreateDocument` | Application action boundary; event dispatch to Channels |
| `EncodeBase64` | UI-adjacent pure/tool utility |
| `DataSourceEvents` | Event boundary helper |
| `ChannelEvents` | Event boundary helper |
| `NodeRouter` | Infrastructure boundary; global singleton/runtime service |
| `Phoenix.PubSub` / `Zaq.PubSub` | Event/PubSub; global runtime service |
| `ChannelConfig` / `Repo` | Storage/database |
| `Channels.Api` | Application/context boundary for Channels role |
| `DataSourceBridge` | External/provider integration boundary |
| Provider bridge modules | External/provider integration |
| `DiskBridge` | External/provider-style bridge over local Storage |
| `Storage`, `FileExplorer`, `EntryCatalog`, `VolumeConfig` | Storage/filesystem/database |
| `WebhookUrl` | Application helper over runtime global config |
| `Zaq.System` | Global singleton/runtime service backed by database |

## D. Test Coverage Map

| Responsibility | Happy path tests | Failure path tests | Edge case tests | Integration behavior tests |
| --- | --- | --- | --- | --- |
| Mount / initial loading | Source selector and provider load tests | Capability raises, no provider config, non-list jobs | No data-source enabled, disk config missing | Source-scope dispatch through Channels |
| Provider browsing/listing | Provider listing and nested folder tests | Provider load errors, unsupported listing | Shared filters root vs nested, stale provider record | Provider bridge stub receives trusted context |
| Navigation/source switching | Disk/provider navigation, source switch tests | Invalid folder/missing id no-op | Breadcrumb stack/go-back/root reset | Switching provider routes via `push_navigate` |
| Selection/view mode | Selection and toggle view tests | N/A | Select all toggles all/none | Render differences list/grid |
| Uploads | Accepted upload, modal closes, provider upload | Mixed valid/invalid, create errors | In-progress upload, relative path fallback, path traversal guard | Upload -> CreateDocument -> Channels -> Storage/provider |
| Raw/new folder create | Folder/raw create tests | Blank fields, path traversal, provider down | Extension append/preserve, alias event | Destination follows active provider folder/scope |
| Rename/move/delete | Rename/move/delete success tests | Missing delete, path traversal, unsupported/move validation | Same-name rename, move into itself, partial bulk delete | Delete dispatches provider/storage removal and ingestion cleanup |
| Ingestion jobs | Ingest file/folder, drawer, filters | Partial/all failure, unexpected router, retry/cancel not found | Hidden mode controls, unknown filter, active jobs count | Creates real IngestJob rows, inline processor stubs |
| Permissions/share | Share modal, add/remove/confirm ACLs | Provider permissions unavailable, sync failure | Duplicate/invalid targets, inherited public, read-only provider modal | Source ACL and document ACL sync |
| Watch/unwatch | Provider watch/unwatch success | Unsupported, missing base URL, provider error, mark-active failure | Inherited watch, no eligible selected, unexpected unwatch response | Provider watcher setup/teardown plus document watch persistence |
| Previews | Disk and provider URL previews | Missing/unavailable/no URL/non-previewable | Blank filename override, malformed path | PreviewHelpers/FilePreviewData integration |
| PubSub/job progress | Job update merge, prep progress | Malformed job, straggler progress | List cap 20, TTL prune/fresh keep | Production-shaped messages update UI state |
| Folder drop | Valid skipped list, batch done | Malformed payload ignored | Empty skipped list, skip list persistence | Client hook state survives modal/upload interactions |

## E. Risk Areas When Changing Dependency Resolution

- `data_source_bridge_module/0` is used in many distinct paths: listing, create/update/delete, source scopes, provider capabilities, provider permissions, provider watch/unwatch, and create-document context. Changing where it is resolved can accidentally make different paths use different bridge modules.
- Capability resolution happens during `mount/3` before entries load. If dependency resolution is delayed or moved, create/list/share/watch buttons may be enabled or disabled differently in production.
- `dispatch_capability_snapshot/2` uses `opts: [bridge_module: data_source_bridge_module()]`, while file actions use `opts: [data_source_bridge_module: ...]`. Those are different option keys consumed by different `Channels.Api` helper paths.
- `CreateDocument.run/2` receives `context: %{event_opts: [data_source_bridge_module: ...]}`. If a dependency is captured on the socket but not forwarded into this context, uploads/raw/folder creation may silently use the default bridge while listing uses an injected bridge.
- `dispatch_source_permission_sync/2` sends the bridge module to an Ingestion event, and Ingestion later dispatches to Channels. A dependency change must preserve that bridge across the service boundary.
- `dispatch_ingest_records/3` currently uses `:ingestion_node_router_module`, but selected records were produced by the data-source bridge. Changing data-source dependency resolution must preserve canonical record attributes (`provider`, `config_id`, `provider_record_id`, `provider_url`, `provider_mime_type`) because ingestion depends on them.
- `with_provider_attrs/2` is central: it enriches every provider record with the current socket provider/config. If dependency resolution changes source/provider selection timing, record sources and permission/watch targets can change.
- Watch support combines provider capabilities with `Zaq.System.get_global_base_url/0`. Dependency changes around provider capabilities can alter watch UI even if base URL behavior is unchanged.
- Disk is just another data-source from this LiveView's point of view, but its bridge crosses into Storage. Dependency changes that work for remote provider stubs can accidentally bypass DiskBridge/Storage behavior.
- `Zaq.Config.get(..., [])` falls back to application env. Replacing one application-env read without changing the call-site opts can leave production behavior unchanged but tests still globally coupled.
- PubSub updates call `load_entries/1`, so dependency resolution must remain available for later `handle_info/2` callbacks, not only for initial mount events.
