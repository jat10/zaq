# Test warning audit

Observed on 2026-10-26 with Elixir 1.20.4 / OTP 28, starting from commit
`365b3cb84`. Dependency revisions are recorded in `mix.lock`.

Scope: remove warnings through direct test/build fixes, preserve test scenarios
and assertions, and report changes needed in production or dependency code.
No production source, dependency pins, or logging levels were changed. No
Beadwork issue was created, as requested.

Action reuse: not applicable — no application operations were added or changed.

## Direct fixes applied

| Warning | Fix |
| --- | --- |
| Four unmatched files under `test/repro/` | Added a scoped `test_ignore_filters` entry in `mix.exs` for these opt-in reproduction scripts. The normal test loading rule is unchanged. |
| Unused `stub_responses/1` | Removed the unused private helper from `test/zaq/channels/disk_bridge_test.exs`. |
| Unused `ServerManager` alias | Removed it from `test/zaq/agent/agent_test.exs`. |
| Unused `require Logger` | Removed it from the workflow startup recovery, workflow dispatch event, and event registry tests. Their ordinary Logger function calls do not need `require Logger`. |
| Migration module redefinition | Guarded migration loading in the disk-volume migration and legacy-history cutover tests. Reuse the module already loaded by migration execution. |
| FTS migration redefinition / undefined functions on an already migrated database | Moved the guarded `RebuildMultilingualContentTsv` load before the test module so its functions are available during compilation as well as execution. |
| SMTP helper access to nonexistent `socket.assigns` | Removed the fallback branch following the branch that already matches every socket containing `assigns`. The removed branch could not successfully perform that access. Both status helpers retain their supported state shapes. |
| Routing test fetching a nonexistent `retrieval_channel_id` | Match `Map.fetch(scope, :retrieval_channel_id)` before looking up the channel. Existing agent-only and channel-scoped scenarios and assertions are preserved. |

These account for 14 warning occurrences in the initial log. The initial run
also compiled dependencies; comparing its total directly with a cached rerun
would incorrectly count dependency warnings as fixed.

## Intentional test warnings retained

The following files are unchanged. Runtime function captures and an extracted
assertion helper were reverted at the user's request. No compiler-warning
suppression has been added.

| Location | Warning and cause | What resolution would require |
| --- | --- | --- |
| `test/zaq/channels/jido_connect_bridge_coverage_gaps_test.exs`, webhook validation test | Calling `process_verified_webhook_job(:not_a_map)` conflicts with its inferred map input type. The test deliberately asserts `FunctionClauseError`. | Keeping this exact direct invalid call retains a legitimate compiler diagnostic. Changing the production API to return a validation error would change its contract and require explicit approval to update the test. No production defect is established by this warning. |
| `test/zaq/channels/communication_bridge_test.exs`, invalid actor test | Calling `route_incoming_message/3` with `:invalid_actor` conflicts with its inferred map input type. The test deliberately asserts `FunctionClauseError`. | Same tradeoff: retain the warning, or explicitly agree on a different runtime validation contract and update production behavior and the corresponding assertion. |
| `test/zaq/engine/connect/credential_resolver_test.exs`, generated matrix | Six warnings on `selected.id` in generated cases where both grants are absent. The shared test body contains an active-grant assertion branch even for these cases; the compiler sees both grants as `nil`. | A structural test-only fix is to generate separate bodies for successful and unsuccessful expectations, preserving all 96 matrix cases and every assertion. This is left for review rather than hiding the type information behind another function. No production change is indicated. |

## Dependency changes needed

Paths below are relative to each dependency's directory under `deps/`. These
warnings appeared while dependencies compiled. A cached run does not prove them
fixed. Apply fixes upstream or in a reviewed fork, then update the pin and validate
the integration; editing the local dependency cache is not a durable solution.

| Dependency / location | Observed warning | Required change |
| --- | --- | --- |
| `phoenix_ecto`, `mix.exs`; `phoenix_live_dashboard`, `mix.exs` | Deprecated `xref: [exclude: ...]` (two occurrences). | Replace the deprecated project option with `elixirc_options: [no_warn_undefined: ...]`, preserving the existing optional-module exclusions. This migrates an existing build declaration. |
| `nostrum`, `lib/nostrum/api/adapter.ex`, `api.ex`, `voice/supervisor.ex`, `voice/audio.ex`, `voice/payload.ex` | Five unused `require Logger` declarations. | Remove the unused declarations in dependency source. |
| `nostrum`, `lib/nostrum/voice/crypto.ex` and `voice/opus.ex` | Seven bitstring-size warnings: three `ext_len` uses, `cipher_text_length`, `tag_length`, `unpadded_nonce_length`, and `body_len`. | Pin externally bound sizes in bitstring matches, for example `size(^ext_len)`, and run voice crypto / Ogg parsing tests. |
| `nostrum`, `lib/nostrum/struct/embed.ex`, fallback `put_field/4` clause | Struct update expects a `Nostrum.Struct.Embed`, but the fallback input is unconstrained. | Establish the supported input contract. If only embeds are supported, pattern-match the fallback on `%__MODULE__{}` before updating it. If maps are supported, implement explicit map-to-struct conversion and test that contract. |
| `phoenix_live_dashboard`, `lib/phoenix/live_dashboard/pages/ecto_stats_page.ex`, `format/2` | `Postgrex.Interval.to_string/1` unavailable during compilation. | Correct the optional Postgrex dependency / compilation relationship. The pinned Postgrex source does define this function; do not treat this as a removed API or hide it through a dynamic call. Verify both Postgrex-present and Postgrex-absent builds. |
| `phoenix_storybook`, `lib/phoenix_storybook/entries.ex` | Unused `require Logger`. | Remove the unused declaration. |
| `phoenix_storybook`, `lib/phoenix_storybook/live/story/playground_preview_live.ex`, `assign_variations_attributes/2` | Passes `nil` into `/3`, whose inferred input expects a variation or group. | Handle the no-variation case explicitly, assigning the empty variation state without entering variation/group processing. Preserve rendering behavior for empty, single, and grouped variations. |
| `phoenix_storybook`, `lib/phoenix_storybook/live/story/playground.ex`, `attr_input/1` | Redundant clause with the same non-nil `values` pattern and guard as the preceding clause. | Remove the unreachable duplicate; verify the select-input story. |
| `web_widget`, `lib/web_widget/integration/verified_profile.ex` | Unreachable fallback clauses in `email?/1` and `phone?/1`. | Remove redundant private fallback clauses after confirming all callers retain the preceding `text?/2` validation. Preserve malformed-profile rejection tests. |

No compiler warnings in ZAQ application source were observed during the initial
application compilation. The source changes listed above belong to dependencies
that ship with the application, so they were not included in this test cleanup.

## Startup and runtime diagnostics

These are distinct from compiler warnings and should not be silenced to make the
test output appear clean.

| Diagnostic | Evidence and next change/investigation |
| --- | --- |
| Configured application `:license_manager` is unavailable | `config/config.exs` unconditionally sets its repo, while this checkout has no corresponding dependency. Decide whether configuration belongs with the optional add-on, or whether the application must be installed. Change the production configuration at its owner once that contract is confirmed. |
| IMAP listener reports `:unable_to_connect` | The baseline emitted retries for an `email:imap_<id>` listener outside captured test output. Audit listener ownership, injected adapters, and cleanup in email runtime tests. Use the existing fake IMAP server where appropriate; establish whether a production runtime restart escapes test cleanup before changing production code. The log alone does not prove which test owns the leaked listener. |
| `Telemetry.Buffer` cannot find a SQL Sandbox owner | The baseline logged repeated flush errors. Audit which test leaves buffered points or a live timer after its owner exits; ensure test-owned processes and database access have matching lifetimes. This is an error log, not a compiler warning, and needs a reproducible isolation diagnosis before choosing a test or production fix. |
| `EventRegistry` cannot load trigger state at startup because it has no SQL Sandbox owner | Reproduced in the full rerun. Trace who starts or restarts the globally registered registry and when its database owner exits. Tests should supervise their own registry instances or explicitly arrange ownership for the intended process lifetime; determine whether application supervision also needs a lifecycle fix. |
| MCP sync / tool hydration reports `:no_tools_discovered`, accompanied by transport and task errors | The full rerun logged this for a `Bridge MCP Timeout Agent`, named by the timeout scenario in `test/zaq/channels/jido_chat_bridge_test.exs`. Audit the timeout test's background dispatch, MCP client lifetime, and local server teardown. Distinguish the intended timeout from work that continues after the test owner exits; synchronize and clean up test-owned work, or repair production cancellation if it cannot be stopped through the supported lifecycle. The suite passed despite these logs. |

## Validation

- Initial `mix test`: collected dependency and test warnings, but did not finish
  within the execution limit; no baseline suite pass is claimed.
- Focused run of the ten affected test files: 281 passed, 8 excluded. This run
  exposed the FTS compile-time load issue subsequently corrected.
- FTS tests after that correction: 36 passed, 8 excluded, no compiler warnings.
- `mix q` in its normal development environment: passed (formatting, hook
  verification, strict Credo, documentation generation, compilation).
- Full `mix test --seed 365326`: passed in 641.1 seconds; 11,664 passed
  (48 doctests, 285 properties, 11,331 tests), 1 skipped, 155 excluded.
  Eight retained test compiler warnings were emitted. Dependency compilation
  was cached; the 21 dependency warnings from the initial run remain unresolved.
- Final `mix precommit`: passed formatting, strict Credo, compilation with
  warnings as errors, and the stale-test run (11,664 passed, 1 skipped,
  155 excluded; seed 243245; 641.0 seconds of test execution). Its eight test
  compiler warnings remain; the compile gate does not turn test-file warnings
  into errors. Context Mode's tool connection timed out after 300 seconds, but
  the command continued under its 900-second limit and its saved log records
  completion. No test failure was reported.

E2E and coverage expansion are not applicable: this cleanup changes neither
production behavior nor the assertions and scenarios of existing tests.
