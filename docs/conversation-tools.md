# Persistent conversation tools

These tools operate on existing durable conversations; they do not introduce a
second persistent entity or runtime.
The runtime supplies caller conversation/workspace/run identity. Tool arguments
cannot supply identity or a cross-workspace grant. Path-unsafe IDs, missing identity,
and metadata marked `visibility: internal` or `task` are rejected. The bounded
internal `task` tool remains separate: its conversations are excluded from these
persistent conversation tools, and its run-scoped authorization and cleanup remain intact.

## Discovery and inspection

- `list_conversations`: browse recent durable conversations without a search term. It accepts
  `archived: active | archived | all`, an inclusive ISO-8601 `updated_after`, and
  a maximum of 20 results. Each summary includes persistent message/run/tool counts
  and the last persisted run result; it never probes runtime processes.
- `find_conversation`: search titles using a required non-empty substring. It uses the
  same filters, pagination, and summary schema as `list_conversations`. Search remains
  metadata-only: it does not search or load transcript bodies.
- `read_conversation`: inclusive zero-based message range; at most 16,000 Unicode
  codepoints and 50 message fragments per page. Stable message IDs and character
  offsets allow long single messages to continue without silently dropping tails.
  It returns visible text by default; `include_tools: true` adds bounded, redacted
  persisted tool summaries and outputs.
- `get_conversation_status`: idle/running/awaiting_approval and available last result.
  No Session is required. Idle is not proof of successful completion.
- `get_conversation_trajectory`: a versioned observability projection over persistent
  conversation facts. `summary` returns aggregate stats plus bounded run/turn summaries;
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
  conversation model; the full catalog is never added to the prompt.

Trajectory uses Handbean's own execution hierarchy:

```text
conversation
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
workspace; there is no per-conversation opt-in. Conversations may exchange any number
of handoffs (for example one conversation develops while another verifies), and a
woken run gets no extra turn or token cap; its length is up to the model. Wakeups
are paid runs. Created children keep a persisted parent route for the
`reply_to_parent_conversation` convenience, but may also message any authorized visible
peer. Creator is provenance, not a fixed completion route.

`send_conversation_message` always uses Coordinator; running conversations default to
`steer`, with `follow_up` only by explicit input. `create_conversation` inherits the
caller's current model when `model` is omitted or is `current`. To select another
model, use the complete workspace-allowed id returned by `list_models`. The child
resolves that model's provider config itself; it does not copy the caller's
provider module or provider config. Later wakes of a pinned child keep that model.

`create_conversation` defaults to a persistent read-only child in the same shared
directory, **not an isolated checkout or sandbox**. The child is a separate
persistent conversation and uses this workspace's permission mode (safe / smart review / yolo);
it does not take a separate approval. `mode: write` removes the read-only
allowlist so the child can edit this workspace. A runtime execution allowlist
still rejects mutating, shell, browser, extension and unknown tools on
read-only children. Workspace search, `web_fetch`, `mem_recall`, `skill`, and
`tool_search` stay available; the provider-visible catalog is the same
allowlist so the child does not see denied tools.

Messages are capped at 8,000 characters.

Every send requires a caller-scoped `request_id`; identical retries return the
existing receipt and different content/target under that key is rejected.
Each independent send/delegation creates a runtime-owned `handoff_id`, returned
in the receipt and visible in `read_conversation`. Continue an exchange by passing that
ID to `send_conversation_message` or `reply_to_parent_conversation`; it must already belong to
the authorized source/target pair. Omitting it starts a new exchange. Every new
origin also persists a `purpose` and trusted `expect_report` fact:

- `request` expects a terminal report.
- `result` fulfills only matching requests already consumed by the sender's current run.
- `progress` and `notification` neither create nor fulfill report responsibility.

When omitted, `purpose` defaults to `request` for a new handoff and for messages
from its original initiator, and to `result` for messages from its original
responder. Those are compatibility defaults, not inferred local roles: reverse
questions and their answers in a multi-round handoff must set `purpose` explicitly.
Changing purpose under the same `request_id` is an idempotency conflict.

A result reservation records the exact covered inbound IDs before dispatch while
holding the source workspace lock. A later request consumed in the same run is not
covered by an earlier result. Historical entries without purpose are not guessed
into new responsibility. Automatic reports carry a runtime-only trusted marker and
never create another report, preventing acknowledgment loops.
The source transcript holds a durable dispatch reservation before Coordinator is
called. This is **at-most-once dispatch**, not exactly-once delivery: a crash or
failure after reservation returns/leaves `delivery_unknown` and is never replayed
automatically. A human should inspect the task conversation before deciding what to do.
No claim of consumption or completion follows from a started/enqueued receipt.
Target transcript `consumption` records actual runtime injection separately.

On normal Runner completion, each consumed request group that has not been
fulfilled receives one deterministic terminal report. The bounded final body is
included only when every external or conversation-origin `user_msg` consumed by that run belongs
to that same peer and handoff; mixed user input, purpose, peer, or handoff yields
only an objective run-status notice. Every non-`completed` terminal status (including
error, timeout, cancellation, halt, stall, budget, or turn-limit endings) sends
a separate sanitized status event to every request group consumed by that run,
even if a result was sent earlier. Approval wait is not terminal. Repeated terminal
callbacks reuse the same reservation. This callback is supervised but not a
durable retry worker: a host crash before it runs may require manual inspection.
A `delivery_unknown` reservation is an already-attempted send and is never replaced
with a second automatic attempt. Run completion is not task acceptance.

## UI

One compact entry per associated handoff (even with the same peer) expands existing persisted reports using native
`details`; there is no input box or separate channel/storage. The summary shows the delegated child's access (`read-only` or `write`) from collaboration metadata, on either side of the exchange. A peer without that metadata has no access label. Important parent
reports remain visible in the main timeline. Source titles/links come from
authorized metadata, never body text. Unavailable sources show a placeholder.
Human text cannot impersonate the report card. Known webhook/SNS/scheduler inputs
have a separate automatic-origin label. Opening, refreshing or expanding is
read-only and never dispatches or wakes an agent.
Older entries without association metadata remain separate rather than guessing
task membership from the peer or body text.
