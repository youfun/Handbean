# Persistent thread tools

Threads are existing durable conversations, not internal tasks or a second runtime.
The runtime supplies caller conversation/workspace/run identity. Tool arguments
cannot supply identity or a cross-workspace grant. Path-unsafe IDs, missing identity,
and metadata marked `visibility: internal` or `task` are rejected. The bounded
internal `task` tool remains separate: its conversations are excluded from these
persistent thread tools, and its run-scoped authorization and cleanup remain intact.

## Discovery and inspection

- `list_threads`: browse recent durable threads without a search term. It accepts
  `archived: active | archived | all`, an inclusive ISO-8601 `updated_after`, and
  a maximum of 20 results. Each summary includes persistent message/run/tool counts
  and the last persisted run result; it never probes runtime processes.
- `find_thread`: search titles using a required non-empty substring. It uses the
  same filters, pagination, and summary schema as `list_threads`. Search remains
  metadata-only: it does not search or load transcript bodies.
- `read_thread`: inclusive zero-based message range; at most 16,000 Unicode
  codepoints and 50 message fragments per page. Stable message IDs and character
  offsets allow long single messages to continue without silently dropping tails.
  It returns visible text by default; `include_tools: true` adds bounded, redacted
  persisted tool summaries and outputs.
- `get_thread_status`: idle/running/awaiting_approval and available last result.
  No Session is required. Idle is not proof of successful completion.
- `get_thread_trajectory`: a versioned observability projection over persistent
  thread facts. `summary` returns aggregate stats plus bounded run/turn summaries;
  `compact` additionally returns record metadata; `full` adds redacted persisted
  content and tool input/output. Full means the complete persisted projection
  available on that page, never unbounded raw output. Record pages are limited to
  50 records and 16,000 characters. The tool is deferred and is loaded through
  `tool_search` when execution-history inspection is needed.
- Discovery/read cursors bind the caller, target/query, and projected snapshot and
  expire after one hour. Changes invalidate the cursor; callers restart rather
  than silently skipping or repeating data. Trajectory cursors additionally bind
  the entry/run/turn revision snapshot and the last consumed record sequence.
- `list_models`: bounded, paginated id/name search over models allowed by the
  current workspace. It is only needed to select a model other than the current
  thread model; the full catalog is never added to the prompt.

Trajectory uses Handbean's own execution hierarchy:

```text
thread
  └── run       one admitted user request and its complete execution
       └── turn one provider completion attempt inside the native loop
            └── durable user / assistant / tool / system records
```

Run and turn lifecycle boundaries are durable facts. Entries carry `run_id` and,
when captured by the current runtime, `turn_number`. Tool timings are recorded at
the individual invocation boundary rather than copying batch duration. Historical
entries created before trajectory capture remain readable but report
`fidelity: partial` with explicit missing dimensions; the projection never invents
turn boundaries or exact timings.

## Handoffs and delegation

Any visible conversation may message another visible conversation in the same
workspace; there is no per-conversation opt-in. Threads may exchange any number
of handoffs (for example one thread develops while another verifies), and a
woken run gets no extra turn or token cap; its length is up to the model. Wakeups
are paid runs. Created children keep a persisted parent route and
cannot delegate further or message arbitrary peers. `reply_to_parent_thread`
takes no target.

`send_thread_message` always uses Coordinator; running conversations default to
`steer`, with `follow_up` only by explicit input. `create_thread` inherits the
caller's current model when `model` is omitted or is `current`. To select another
model, use the complete workspace-allowed id returned by `list_models`. The child
resolves that model's provider config itself; it does not copy the caller's
provider module or provider config. Later wakes of a pinned child keep that model.

`create_thread` defaults to a persistent read-only child in the same shared
directory, **not an isolated checkout or sandbox**. `mode: write` removes the
read-only allowlist so the child can edit this workspace. Write mode does not
raise a separate approval. Its prompts use smart review (`approval` defaults to
`auto_review`). `approval: yolo` skips those prompts for that child only and
does not change workspace settings; built-in sensitive-path denies still apply.
A runtime execution allowlist still rejects mutating, shell, browser, extension
and unknown tools on read-only children, including after approval/resume.

Messages are capped at 8,000 characters.

Every send requires a caller-scoped `request_id`; identical retries return the
existing receipt and different content/target under that key is rejected.
Each independent send/delegation creates a runtime-owned `handoff_id`, returned
in the receipt and visible in `read_thread`. Continue an exchange by passing that
ID to `send_thread_message` or `reply_to_parent_thread`; it must already belong to
the authorized source/target pair. Omitting it on send starts a new exchange,
not a continuation based on peer identity. Retries keep the same request and
association. Both the source reservation and recipient's trusted origin retain
the association. Replies inherit the initiating run's association (or original
child delegation); replies to a different queued task must select its ID
explicitly. Terminal reports retain the initiating association too.
When multiple associations were consumed in one run, its unpartitioned assistant
text is not copied into a task-specific terminal report: only a run-status notice
is returned. Explicitly associated replies carry the individual results.
The source transcript holds a durable dispatch reservation before Coordinator is
called. This is **at-most-once dispatch**, not exactly-once delivery: a crash or
failure after reservation returns/leaves `delivery_unknown` and is never replayed
automatically. A human should inspect the task thread before deciding what to do.
No claim of consumption or completion follows from a started/enqueued receipt.
Target transcript `consumption` records actual runtime injection separately.

On normal Runner completion, a child sends a bounded final report unless that run
already explicitly replied. This callback is supervised but not a durable retry
worker: a host crash before the callback may require manual inspection. No
automatic acknowledgment is sent.

## UI

One compact entry per associated handoff (even with the same peer) expands existing persisted reports using native
`details`; there is no input box or separate channel/storage. The summary shows the delegated child's access (`read-only`, `write`, or `write · yolo`) from collaboration metadata, on either side of the exchange. A peer without that metadata has no access label. Important parent
reports remain visible in the main timeline. Source titles/links come from
authorized metadata, never body text. Unavailable sources show a placeholder.
Human text cannot impersonate the report card. Known webhook/SNS/scheduler inputs
have a separate automatic-origin label. Opening, refreshing or expanding is
read-only and never dispatches or wakes an agent.
Older entries without association metadata remain separate rather than guessing
task membership from the peer or body text.
