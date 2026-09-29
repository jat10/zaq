# LiveRAG source extraction

The [corpus preparation contract](../../../docs/exec-plans/liverag-corpus-preparation.md)
pins the upstream input and describes the later ingestion stages. This directory
contains the pinned source extractor, isolated corpus migrations, and operator
commands. Generated data is ignored by Git.

With the project's Mix dependencies installed, run:

```sh
mix liverag.corpus extract
```

The command downloads the pinned Parquet file into `data/`, verifies its size
and SHA-256, and writes `documents.jsonl`, `aliases.jsonl`, `mappings.jsonl`, and
`manifest.json` in the same ignored directory. It refuses a cached source file
with the wrong digest. It reports counts from parsed rows and does not ingest
anything into a ZAQ database. `Zaq.Bench.LiveRAG.Dataset.load/1` checks the pin,
output digests, counts, and mapping references before the runner consumes
the files. The extractor uses Explorer to read Parquet and is available in the
development and test Mix environments. `--data-dir` selects another output
directory.

Provision an empty disposable PostgreSQL database with the `vector` extension
and the same compatible text search configurations as the target retrieval
environment. The first `ingest` command creates only corpus document, chunk,
and checkpoint tables. It refuses unexpected tables, a nonempty unmanaged
`documents` table, and a mismatched vector dimension. Keep this database
separate from ZAQ's configured source database.

```sh
mix liverag.corpus ingest 10 --corpus-url "$CORPUS_DATABASE_URL" --person-id 42
mix liverag.corpus inspect --corpus-url "$CORPUS_DATABASE_URL"
mix liverag.corpus retry 12,13 --corpus-url "$CORPUS_DATABASE_URL" --person-id 42
mix liverag.corpus export --corpus-url "$CORPUS_DATABASE_URL" --output-dir /path/to/liverag-artifact
mix liverag.corpus verify --corpus-url "$CORPUS_DATABASE_URL" --artifact-dir /path/to/liverag-artifact --restore-url "$EMPTY_RESTORE_DATABASE_URL"
```

Use the ID of a person authorized to resolve the configured embedding
credential. `--source-url` can select a different source database, and
`--data-dir` can select a previously extracted directory. An ingest invocation
selects at most 100 documents and defaults to at most 100 provider requests,
five minutes, and 100 ms pacing between requests. Override the latter limits
with `--max-requests`, `--deadline-ms`, `--pace-ms`, and `--attempts`. The
runner uses one provider request at a time and never retries a failed chunk
until its checkpoint ID is supplied to `retry`. `inspect` shows those IDs and
fixed error codes without provider response bodies or credential material.
An incomplete, busy, or failed run exits unsuccessfully, so automation should
use `inspect` to distinguish its state. Run commands in small batches; no
command starts a full-corpus run implicitly.

`export` requires every pinned document and prepared chunk to be complete and
every stored vector to be nonzero. It writes a custom-format `corpus.dump`,
the verified source JSONL files, and a manifest with hashes of every file,
row content, indexes, and sequence state. The dump contains only `documents`
and `chunks`; checkpoint and source configuration tables are excluded.
`verify` requires a separate, empty disposable database with the `vector`
extension already installed. It restores the dump and compares its rows,
vector dimension, indexes, and sequences against the export manifest. Treat a
failed restore target as disposable and recreate it before another attempt.

The pinned input was parsed locally and yielded 895 question mappings, 970
unique supporting documents, and 970 source ID aliases. The generated manifest
records the exact counts and hashes for each run.
