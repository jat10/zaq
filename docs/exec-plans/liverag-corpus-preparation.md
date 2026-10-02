# LiveRAG corpus preparation

This document records the corpus-only design tracked by [#819](https://github.com/www-zaq-ai/zaq/issues/819)
and Beadwork epic `zaq-f9w`. The implementation sequence and progress live in its child issues,
`zaq-f9w.1` through `zaq-f9w.8`. The current checkout is based on retrieval
work in [#814](https://github.com/www-zaq-ai/zaq/pull/814); that pull request
is a code baseline, not the corpus specification.

## Scope and input contract

Prepare a reproducible, restorable corpus for a later LiveRAG smoke run. The
deliverable is the supporting-document corpus, its source and ID mappings, a
database dump, and a secret-free manifest. No full-corpus ingestion, query
preparation, retrieval evaluation, answer generation, or live smoke execution
belongs to this epic. Ingestion must be explicitly requested in small batches;
creating the runner must not start a full run.

The input is the `LiveRAG/Benchmark` file
`LiveRAG_banchmark_20250910.parquet` at [dataset revision
`9deaaa8efdbf4e04be758a0333736a2ccd0216a2`](https://huggingface.co/datasets/LiveRAG/Benchmark/tree/9deaaa8efdbf4e04be758a0333736a2ccd0216a2).
Its expected size is 4,718,428 bytes and its SHA-256 is
`8282bd5cf806030a432674abefe2f02d8f8134561dbe42c1e14b784a1f67010e`,
verified against the downloaded bytes and the upstream LFS object. The extractor
verifies that digest before parsing. An unpinned latest-version download is not
a substitute. A manifest records the exact pin, extraction
version, content hashes, counts actually observed, and deterministic source-ID
mapping. Included document IDs and content are deduplicated deterministically;
conflicting content for one ID or malformed records fail visibly rather than
silently selecting a winner. Preserve source-to-document mappings needed to
trace every stored document back to the pinned input.

## Isolation and configuration

The preparation command is an ordinary benchmark application boundary with a
thin Mix task, outside BO request handlers and the Agent runtime. It uses
distinct connections for the source configuration database and disposable
corpus database. The benchmark makes no source writes; canonical credential
resolution still takes its existing row locks, so the source connection must
allow those locks. All document, chunk, checkpoint, and
artifact writes target the corpus database; production configuration tables
must not be copied into its export.

Resolve embedding provider, model, dimension, endpoint, and authentication from
the persisted System configuration and its canonical Engine/Connect credential
flow described in [system configuration](../services/system-config.md). Preserve
the same authorization checks and use only the minimum confidential values in
memory. Reject OAuth-backed credentials before obtaining the corpus run lock;
do not refresh a grant or mutate the source database. Never print or export
secrets, tokens, decrypted values, or connection strings. Record a secret-free
configuration fingerprint so resume rejects a changed model, dimension,
endpoint identity, input pin, or extraction/chunking contract. The fingerprint
must not be reversible into secret material.

## Processing and persistence

Reuse [Ingestion's](../services/ingestion.md) `DocumentProcessor` chunk
preparation and persisted document/chunk shape. Extract the existing chunk
storage path into a shared owner rather than copying its metadata, vector,
dimension, or half-vector rules into benchmark code. `Embedding.Client` gains
only the snapshot, bounded retry, and redacted-error seams needed to hold one
run's resolved configuration; normal production calls keep their existing
behavior. Keep configured `zaq_router` routing. Validate dimension and reject
zero or invalid half-vectors before a chunk is marked successful.

The preparation database owns constrained run, document, chunk, and attempt
state. A document and its expected chunk identities are recorded atomically
before network embedding work. An attempt stores enough non-secret diagnostic
information to inspect a failure without repeating it automatically. Persist a
successful chunk and its checkpoint in one transaction; a crash before commit
leaves the chunk unfinished, and a replay cannot create a duplicate or replace
a successful embedding. Retrying a failed chunk is an explicit operator action
recorded as a new attempt. Transient retry inside one attempt is bounded by
configured count, pacing, and deadline. Do not re-embed successful chunks on
resume.

### Exclusive ownership and stale-worker fencing

One dedicated PostgreSQL connection to the corpus database holds a session-level
advisory lock for the entire run. A transaction-scoped lock is insufficient: the
runner performs network calls between short write transactions. The runner
stops scheduling work immediately if that session or lock is lost. Every write
transaction checks the current run's persisted generation/fence token and
ownership state before committing. A replacement runner advances the fence
under the lock, so a worker started by an older owner cannot commit a late
result even if its embedding request finishes. No database transaction stays
open across network work. Lock contention returns an explicit busy result;
it must not start a second worker or silently steal the active run.

## Operator commands and artifacts

`ingest 10` deterministically selects at most ten unfinished documents in
source order. It resumes from persisted state, observes one configuration
snapshot, bounds concurrent requests and total work, and reports completed,
unfinished, and failed counts. `inspect` exposes progress and redacted
attempt-level errors without changing state. `retry` requires explicit IDs and
does not reset successful chunks. Exit status distinguishes complete, incomplete,
busy, and failed runs. Command spelling and options are finalized with the
runner in `zaq-f9w.6`; scripts and documentation must agree.

Export is allowed only after completeness checks reconcile the selected source
documents, expected chunk identities, stored vector validity, and run state.
Produce `corpus.dump`, source records, mappings, and a manifest containing
checksums for every artifact; exclude configuration, grants, credentials, tokens,
and attempts that could contain provider responses. Restore into an empty,
disposable, isolated database and compare source/document/chunk counts, content
hashes, indexes, and sequence state. Refuse a nonempty or unexpected target.
The restore verification proves artifact integrity, not live retrieval quality.

## Step contracts and evidence

| Issue | Deliverable and immediate verification | Action reuse assessment |
| --- | --- | --- |
| `zaq-f9w.1` | Save this contract and verify links and issue dependencies. | Not applicable: documentation only. |
| `zaq-f9w.2` | Pinned Elixir extractor and dataset module; test checksum mismatch, malformed input, ID/content conflicts, and deterministic output. | Local-only extraction: no existing ZAQ Action owns parsing a pinned external benchmark archive. Recheck source and candidate Actions before code. |
| `zaq-f9w.3` | Separate read-only source and writable corpus pools; test source nonmutation, target isolation, secret redaction, OAuth refusal, and fingerprint changes. | Reuse System and Engine/Connect credential resolution; no parallel secret or authorization path. The benchmark snapshot is local lifecycle state. |
| `zaq-f9w.4` | Shared chunk persistence and embedding snapshot seams; test production parity, router selection, dimensions, zero vectors, retry exhaustion, and redaction. | Extend existing `DocumentProcessor`/`Embedding.Client` ownership; no new agent Action or tool exposure. |
| `zaq-f9w.5` | Run/checkpoint schema and locked transaction API; test crash recovery, uniqueness, concurrent owners, stale commits, and explicit retry. | Local-only run state and fencing: a benchmark-specific persistence/lifecycle boundary, not an agent operation. Reuse Ecto changesets and `Repo` transactions. |
| `zaq-f9w.6` | Bounded runner and Mix commands; test deterministic selection, resume, pacing, deadlines, errors, inspect and retry. | Reuse shared ingestion/embedding logic; orchestration remains a local benchmark command, not an agent tool or workflow Step. |
| `zaq-f9w.7` | Secret-free export and disposable restore verifier; test incomplete refusal, checksum mismatch, nonempty target, schema/index/sequence mismatch. | Reuse PostgreSQL backup/restore primitives and persisted corpus contracts; benchmark artifact assembly is local-only. |
| `zaq-f9w.8` | Automated sample with a stubbed provider, real database and export/restore; report exact smoke prerequisites and limitations. | Not applicable: validation and reporting add no executable operation. |

Before each implementation issue, expand its Action reuse evidence in Beadwork
with actual candidates, inputs, outputs, errors, permissions, consumers, and
tests under [the Action reuse gate](../action-reuse.md). The table is a decision
outline, not a substitute for that source audit. Tests at the database boundary
must check rollback, stale ownership, and negative permission cases; property
tests should cover deterministic deduplication and checkpoint invariants. No
browser UX is added, so the feature E2E approval gate does not apply. The final
automated sample is an integration test, not a live smoke run.

## Acceptance stages

1. `zaq-f9w.1` records the contract and input pin; `zaq-f9w.2` proves the
   source set is deterministic and traceable.
2. `zaq-f9w.3`–`.5` establish isolated configuration, production-equivalent
   persistence, and crash-safe ownership before scheduling any batches.
3. `zaq-f9w.6` proves bounded, explicit, resumable ingestion on a small
   fixture. It does not initiate the full corpus.
4. `zaq-f9w.7` proves export and restore in an empty disposable database.
5. `zaq-f9w.8` runs the automated sample and records live-smoke prerequisites,
   limitations, issue-level checks, and the final validation gate from
   [the agent workflow](../WORKFLOW_AGENT.md#phase-4--validate).

## Validation and live-smoke readiness (2026-09-29)

The pinned extractor verified the 4,718,428-byte source file and produced 970
unique supporting documents, 970 source aliases, and 895 question mappings.
The generated records remain ignored local inputs; this work has not embedded
or exported the full corpus. The repeatable two-document integration sample is
`mix test test/bench/liverag_smoke_test.exs --include integration`. It creates
two disposable PostgreSQL databases, uses a deterministic stub vector,
ingests one document per call, rejects a concurrent lock contender, exports only `documents` and `chunks`, restores
the dump, compares rows/indexes/sequences, and checks nonempty-target and
checksum refusal. The sample uses synthetic document text with the approved
dataset pin so it can prove the pipeline without a provider request.

Before a live smoke run, the operator needs:

1. A source ZAQ database with persisted embedding model, dimension, endpoint,
   and an API-key or unauthenticated credential accessible to an explicit
   authorized person. OAuth credentials are refused without refresh.
2. A distinct, disposable corpus database with the `vector` extension and
   compatible text-search configurations, plus a separate empty restore
   database. The operator must have `pg_dump` and `pg_restore` available.
3. Network access, quota, and a budget for the configured embedding provider.
   Run `mix liverag.corpus ingest 10` in small explicit batches, inspect
   progress and retry only named failed chunk IDs. Export is refused until all
   970 pinned documents and their chunks reconcile; then verify in the empty
   restore database. Exact commands and limits are in
   [the operator README](../../priv/bench/liverag/README.md).

The stubbed sample proves persistence, isolation, restart, and artifact
integrity. It does not prove provider compatibility, embedding quality, recall,
answer quality, or live service throughput. Retrieval evaluation and answer
generation are separate work. No live embedding call or full-corpus ingestion
was performed during this implementation.

The repository's existing BO E2E suite was attempted after installing its
locked Node dependencies. Its bootstrap succeeded, but Playwright could not
launch Chromium in this sandbox: macOS denied Mach port registration
(`bootstrap_check_in`, permission denied 1100). No browser assertions ran.
The affected ingestion and system-configuration journeys still need execution
in a browser-capable environment before final approval.
