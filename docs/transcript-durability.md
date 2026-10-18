# Transcript durability and SQLite storage

Handbean stores conversations, transcript entries, run usage, operation receipts,
editor state, and reconnect snapshots in the SQLite database owned by
`Handbean.Repo`. The packaged host resolves it to `<data_dir>/handbean.db` unless
an explicit Repo database is configured. SQLite is the only canonical online
store: old conversation/session JSON and JSONL files are neither imported nor
used as a fallback.

The Repo is configured centrally for WAL, `synchronous = FULL`, foreign keys,
bounded busy waiting, and automatic checkpointing. Visible assistant deltas are
committed before delivery or Session broadcast. A database-path-specific native
sidecar lock prevents two Handbean runtimes from owning the same database; a
different database in the same directory has an independent lock.

SQLite WAL requires a local filesystem shared by all Repo connections. Do not
place the database on NFS, iCloud Drive, or another synchronized/network mount.
`busy_timeout` can absorb short local writer contention but cannot make remote
WAL/SHM locking safe.

## Transaction boundaries

`ConversationTranscriptStore` remains the public transcript boundary; its
default implementation stores stable envelope fields in indexed columns and
entry-specific data in a JSON payload. Public maps retain string keys and ISO8601
timestamps.

Message admission uses a durable reservation followed by an owner-local commit:

- Runner commits a new-run inbound entry and completes its receipt before the
  provider task starts.
- CandidateQueue validates run identity, seal, and capacity, then commits the
  pending inbound and receipt before adding the message to its in-memory queue.
- Session commits a next-turn inbound, receipt, and snapshot before updating its
  in-memory projection or broadcasting.

This does not make provider, shell, network, or OS side effects exactly-once.
If a process dies after an external effect but before its result commits, the
effect is `unknown` and must not be replayed automatically.

Terminal settlement updates unfinished assistant/tool entries for one run and
records put-once run usage in one database transaction. Startup recovery uses
indexed unfinished-entry queries; it marks orphaned streaming replies and
running tools as failed, retains committed text, and adds one stable error entry
per run. It never reruns tools or redelivers old messages. Only the registered
`TranscriptRecovery` owner may recover internal delegated conversations.

`page/2` returns chronological entries, an exclusive `before` entry-ID cursor,
and `has_more?`; limits are 1–200. A deleted cursor returns
`:invalid_cursor`. Generic patches use revision CAS with bounded retries;
assistant `$append` uses an atomic SQL update so concurrent deltas do not lose
bytes.

## Health, diagnosis, and backup

Run a redacted explicit diagnosis against the active Repo:

```sh
mix handbean.storage
```

It runs `quick_check`, `foreign_key_check`, required table/index checks, reports
the migration version and journal mode, and attempts a passive WAL checkpoint.
A busy checkpoint is reported separately and does not hide the other health
results.

SQLite errors are classified as busy, full, I/O, corrupt, constraint, or
unknown. A corrupt/not-a-database result opens the runtime storage circuit:
new Agent admissions are rejected and Schedule Clock stops dispatching. The
runtime does not delete the database, WAL, or SHM files and does not create an
empty replacement.

Create a consistent online backup with:

```sh
mix handbean.storage --backup /path/to/handbean-backup.db
```

The command uses `VACUUM INTO` to write a temporary snapshot, opens that snapshot
read-only, verifies quick check, foreign keys, and migration version, then
atomically publishes it. It refuses to overwrite an existing target. Never copy
the live database file by itself while the runtime is active.

Restore only while Handbean is stopped and no process owns the target database.
Preserve a damaged database and its `-wal`/`-shm` companions for diagnosis.
There is no canonical JSONL copy from which newer state can be rebuilt.

## Limits and verification

Committed SQLite text survives a BEAM task or host process crash according to
FULL WAL durability. Handbean cannot recover bytes the disk refused to write,
an unacknowledged provider chunk, an unknown external side effect, total disk
loss, or a damaged database without a verified backup.

Desktop unit/host tests do not prove Android or iOS packaging, static-NIF,
filesystem, cold-start, force-stop, or power-loss behavior. Those claims require
the platform-specific matrix in `docs/mobile-device-verification.md`.
