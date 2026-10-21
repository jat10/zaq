# Communication integration test support

This framework exercises real adapters, JidoChatBridge, CommunicationBridge,
NodeRouter, Engine, configured agents and canonical history. Only provider and
LLM services are simulated. Follow the [testing handbook](../../../../docs/testing-approach.md).

## Driver ownership

Implement `Zaq.TestSupport.Channels.Integration.Driver` and register the module
once in `Registry`'s marked `@drivers` list. Source files belong in `drivers/`
with module names `Zaq.TestSupport.Channels.Integration.Drivers.ProviderName`.
Registry validation identifies unregistered files and duplicate entries. The
inventory grows as the initial providers are implemented; completed shared suites
must include Mattermost, Telegram and WhatsApp.

| Callback | Contract |
| --- | --- |
| `start(opts)` | Start a fake external service; return `{:ok, handle}`. Options include `owner_pid` and unique `scope`. |
| `connect(handle, context)` | Start the real connector runtime and complete readiness/pairing; return `{:ok, connected_handle}`. |
| `emit(session, message)` | Send native provider input through real ingress; return `{:ok, emission}`. |
| `script(session, script)` | Queue matched external responses; return `:ok`. |
| `deliveries(session)` | Return ordered successful and failed native requests. |
| `capabilities()` | Require `direct: true`, `shared: true`; extras are `true` or `{:unsupported, reason}`. |

Fallible callbacks may return `{:error, reason}`. `Contract` rejects malformed
results with provider/operation diagnostics; a behaviour declaration alone does
not establish conformance.

Handles carry `provider`, configured `adapter`, `ingress_mode`, `connector_attrs`,
`sender`, `rooms` (direct/shared native coordinates), and `opaque` provider state.
The two startup phases allow a local endpoint to exist before the saved connector,
while pairing uses the connector's actual profile afterward. The case owns agent,
Person and routing fixtures, session resources, and cleanup.

Messages contain `content`, `source_id`, room, sender, timestamp, mention facts and
optional native thread reference. Emissions return `source_id`, `channel_id` and
`thread_id`. Scripts match an operation and relevant request fields before consuming
queued results. Incidental typing/status requests must not consume final-answer
failure scripts. Deliveries retain sequence, operation, provider, connector id,
native channel/thread/message ids, text, outcome and a sanitized native payload.

Read transcripts through `Conversations.list_canonical_messages/3` after actual
Engine delivery confirmation. A generated private execution answer is distinct
from a confirmed public transcript placement. Negative reply assertions require
an ingress completion barrier first. Full runtime suites use `async: false` because
they share application configuration, the agent manager and existing WhatsApp fake.

## Inventory and scope

Mattermost, Telegram and WhatsApp are registered. All shared test modules enumerate
`Registry.all/0`, so registering another driver expands the regression matrix.
`Registry.coverage/1` reports configured Jido communication providers missing a
driver; registration does not imply coverage for every installed adapter.

Mattermost uses native frame callbacks and a local REST endpoint; Telegram uses
native webhooks and a local Bot API URL. WhatsApp reuses the existing
`WhatsAppFlowAdapter` delegating wrapper and `WhatsAppFlowTransport`, completing
headless pairing through real storage callbacks. Its optional request ledgers
are profile scoped and preserve legacy helper defaults. No production transport
injection or encrypted WhatsApp network emulator is needed. Fake sessions remain
synchronous. Native thread input is covered for all three; Telegram/WhatsApp
cannot fetch an arbitrary remote root, so only legitimately captured parent
history is available.

The tests retain three production regressions, tracked in epic `zaq-o9d`:

- `zaq-kxd`: Telegram native group mentions fail the saved `mention_required` gate.
- `zaq-imv`: identical Telegram message ids in distinct chats collide in deduplication.
- `zaq-gr2`: Telegram string thread ids fail ExGram's integer parameter validation.

These are executable failures, with no skips or application/dependency fixes in
this change. They block affected acceptance; independent infrastructure work can
continue. A run containing them must be reported as failing.

## Runtime case

Once the provider driver is registered, a test uses the common case:

```elixir
use Zaq.TestSupport.Channels.Integration.Case

test "a direct message receives an answer" do
  session = channel_session(:mattermost, llm_answer: "Hello Alice")
  emission = emit_message(session, :direct, content: "Hello")
  result = await_exchange(session, emission)
  assert result.reply.body == "Hello Alice"
  assert_transcript(session, emission, "direct", ["Hello", "Hello Alice"])
end
```

`answers: [first, second]` scripts sequential text turns. For a tool turn, supply
`tool_keys`, `tool_routes`, and `llm_final_response`; these reuse the existing
`ToolCallingLLMStub`. Channel fixtures explicitly enable conversation routing.
They do not change `IntegrationAgent`'s existing defaults.

The completion observer watches returns from the real public Channels API. This
ensures delivery confirmation has finished; NodeRouter's initial broadcast and
the provider's receipt alone do not establish that. It filters by connector, and
`await_exchange` additionally matches the persisted input's native source id.
Independent OTP trace sessions are destroyed during supervised cleanup. Setup
restores each configuration key's previous present/absent value and stops only
this session's runtime before its SQL Sandbox owner is released.

`await_exchange/3` also waits for `HistorySync.complete/3` to return for that input,
so the next turn starts after the previous runtime history synchronization.
`emit_message/3` waits for native listener processing when ingress is asynchronous.
The canonical reader returns public projections such as `message_id`, `position`,
`role`, `content`, `author` and timestamps. `captured_message!/2` locates the actual
stored input through its connector/room placement when native provenance is needed.

For example, a direct exchange projects ordered content:

```elixir
{:ok, messages} = read_transcript(session, session.person, transcript!(session, emission).id)
Enum.map(messages, &Map.take(&1, [:position, :role, :content]))
# [%{position: 1, role: "user", content: "Hello"},
#  %{position: 2, role: "assistant", content: "Hello Alice"}]
```

## Response scripts

Only matching provider operations consume results. Successful ids are native
provider ids. Exhausted matching scripts fail explicitly.

```elixir
session.driver.script(session, %{operation: :send,
  match: %{text: "Final answer"}, results: [{:error, :offline}]})
session.driver.script(session, %{operation: :edit,
  match: %{text: "Final answer"}, results: [{:error, :offline}]})
```

Status creation/updates may precede final delivery. Script both terminal operations
when the scenario permits either. To require a final send, script failed creation
by channel so no status id exists. Inspect `session.driver.deliveries(session)`
for ordered native attempts, and the canonical transcript for confirmed content.

## Add an adapter's test driver

The production adapter must already be installed and compiled. The generator
does not implement an adapter or alter dependencies/configuration:

```sh
mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter --dry-run
mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter
```

Dry run prints planned paths and the registry diff without writing. Normal
execution refuses existing files, duplicate registrations, invalid markers and
symlink paths; stale registry data aborts and later-write failures remove owned
output. Generated callbacks intentionally fail until implemented. Generation is
a dev Mix task and does not start ZAQ or require compiled test-support modules.
The [repository skill](../../../../.agents/skills/add-channel-integration-tests/SKILL.md)
guides implementation and full-matrix validation.

```text
lib/mix/tasks/zaq.test.gen.channel.ex             generator tooling
.agents/skills/add-channel-integration-tests/    agent workflow
test/support/channels/integration/
  driver.ex, contract.ex, registry.ex            shared contract and inventory
  case.ex, fixtures.ex, observer.ex               real runtime lifecycle
  assertions.ex, session.ex, provider_state.ex   observations and fake state
  drivers/{mattermost,telegram,whatsapp}.ex       provider implementations
  templates/*.eex                               generator templates
test/zaq/channels/integration/
  round_trip_test.exs                            all-driver Agent scenarios
  transcript_test.exs                            history and access matrix
  delivery_failure_test.exs                      send/edit failures and isolation
  lifecycle_test.exs                             teardown and setup failures
  providers/*_test.exs                           native provider specifics
test/mix/tasks/zaq_test_gen_channel_test.exs       generator contract
```

## Run the tests

```sh
# Focused provider debugging:
mix test test/zaq/channels/integration/providers/whatsapp_test.exs
# Required cross-provider regression matrix, including known failures:
mix test test/zaq/channels/integration test/mix/tasks/zaq_test_gen_channel_test.exs
```

Common tests have `provider` and `scenario` tags for targeted debugging, but are
enabled by default. Run all registered providers after adding a driver or changing
the communication skill. Follow the [validation workflow](../../../../docs/WORKFLOW_AGENT.md#phase-4--validate)
for quality/review/coverage/final gates and include existing adapter regressions.
