---
name: add-channel-integration-tests
description: Scaffold and implement a fake provider driver for an installed ZAQ communication adapter, then run the shared integration and transcript regression matrix.
---

# Add communication adapter integration tests

Use the repository's generator and shared harness to exercise native provider
input through the actual adapter, JidoChatBridge, CommunicationBridge, Agent and
Engine, returning an answer to the fake provider and inspecting canonical history.
This creates test infrastructure for an existing production adapter.

## Context and scope

Follow `AGENTS.md` and its task-specific policy links. Read
[channel contracts](../../../docs/services/channels.md) and the
[harness README](../../../test/support/channels/integration/README.md), including
its Driver and Registry contract references. Inspect the installed adapter's
native input, delivery and authentication contracts before choosing fixtures.

Keep adapter integration work under `test/`. The reusable generator is
`lib/mix/tasks/zaq.test.gen.channel.ex`; this skill lives in `.agents/skills/`.
Production adapter implementation, dependency installation and runtime changes
require separately authorized work. Preserve existing test expectations.

## Workflow

1. Confirm the adapter module already compiles and identify its provider seam:
   local HTTP URL, native frame callback, or the existing WhatsApp delegating
   wrapper. Reuse provider and LLM helpers before adding another fake.
2. Preview, then generate from the project root. Example for an installed Teams
   adapter:

   ```sh
   mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter --dry-run
   mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter
   ```

   If the adapter is unavailable, report the prerequisite. The task deliberately
   refuses overwrites, duplicate entries and unsafe paths. It generates two test
   files and a registry entry; unfinished stubs fail until implemented.
   Check the registry and destination files first. If this integration already
   exists, complete it in place instead of regenerating or overwriting it.
3. Implement all six `Integration.Driver` callbacks in the generated driver.
   `start` owns only the external fake; `connect` receives actual saved fixtures
   and establishes real runtime readiness. Emit native provider input and retain
   native source/room/thread identities. Script exact operation/content matches
   and expose ordered, scoped successful and failed requests. Unknown external
   operations fail visibly. Declare direct/shared support and explain unsupported
   optional capabilities; never disable mandatory cases to obtain a green suite.
4. Use `Integration.Case` for real agent, Person, connector, routing and LLM
   fixtures. Keep routing, accounts, permissions, history and persistence real.
   WhatsApp reuses `WhatsAppFlowAdapter` and `WhatsAppFlowTransport`; saved
   connector delivery already works through that wrapper. Do not add production
   transport injection. Use completion events, not sleeps or database polling.
5. Add provider-specific native payload/readiness/error tests. Registration
   automatically expands `round_trip_test.exs`, `transcript_test.exs` and
   `delivery_failure_test.exs`; do not maintain another provider allowlist.
   Inspect direct/shared history through the real authorized Conversations API.
6. Run focused provider tests, then the entire registered matrix and relevant
   existing adapter regressions. Follow `docs/WORKFLOW_AGENT.md` for quality,
   review, coverage and final validation timing; see the
   [workflow owner](../../../docs/WORKFLOW_AGENT.md#phase-4--validate).

   ```sh
   mix test test/zaq/channels/integration/providers/teams_test.exs
   mix test test/zaq/channels/integration test/mix/tasks/zaq_test_gen_channel_test.exs
   ```

   A provider-only pass does not establish that other adapters still work.
   Record commands/results and any uncovered configured providers in Beadwork.
7. Review the changed-file inventory. Report generated files, actual provider
   coverage, transcript evidence and remaining defects. A genuine production
   failure gets an executable reproducer and a linked bug; retain its assertions.
   Continue independent authorized work while the affected acceptance stays
   blocked. Do not change production or claim a green matrix to close the gap.
   Report the specific scope or capability decision needed when independent work
   is exhausted. This workflow does not authorize publication, commits or pushes.
