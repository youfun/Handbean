# Persistent conversation tools

These tools operate on existing durable conversations; they do not introduce a
second persistent entity or runtime.
The runtime supplies caller conversation/workspace/run identity. Tool arguments
cannot supply identity or mint a cross-workspace grant. Exact cross-workspace operations
are evaluated by the permission boundary: yolo runs proceed automatically, smart review
runs use AutoReview and fall back to human approval, and interactive/safe runs require
human approval. Every approval is bound to one tool call, its exact input, resource, and
operation. Path-unsafe IDs, missing identity, sensitive credential paths, explicit denies,
and metadata marked `visibility: internal` or `task` remain rejected. The bounded
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
- `search_conversations`: literal body search over redacted persisted messages and tool
  records across authorized durable conversations. It returns bounded snippets plus
  stable conversation, run, turn, record-sequence, and entry anchors so a caller can
  inspect the surrounding evidence with `read_conversation` or
  `get_conversation_trajectory`. Unlike `find_conversation`, it locates transcript and
  execution content rather than titles. Redaction happens before final matching, so secret
  source values cannot be recovered by searching for them. The invoking run is excluded:
  the current request and completed search tool calls cannot become their own evidence or
  invalidate pagination. Free chats and internal task conversations are excluded. The
  archive filter defaults to `all`, and results omit a total count rather than performing
  an unbounded scan. This deferred tool is loaded through `tool_search` when
  cross-conversation execution search is needed.
- `list_conversations`, `find_conversation`, and `search_conversations` remain scoped to
  the caller's current workspace; there is no cross-workspace enumeration or body search.
- `read_conversation`, `get_conversation_status`, and `get_conversation_trajectory` may
  inspect a known exact conversation ID in another workspace after boundary authorization.
  Free, internal, and task conversations remain inaccessible even in yolo.
- Discovery/read cursors bind the caller, target/query, and projected snapshot and
  expire after one hour. Changes invalidate the cursor; callers restart rather
  than silently skipping or repeating data. Search cursors likewise become stale when any
  searched source changes; writes from the excluded invoking run do not invalidate them.
  Trajectory cursors additionally bind the entry/run/turn revision snapshot and the last
  consumed record sequence.
- `list_models`: bounded, paginated id/name search over models allowed by the current
  or an exact authorized target workspace. It includes supported/default reasoning
  levels but never provider credentials. Listing a target catalog and creating a target
  conversation are separate authorized operations.

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

Search matches are evidence locators, not semantic memory or inferred facts. Use their
stable anchors with the follow-up readers to inspect context before drawing conclusions.

## Handoffs and delegation

Any visible workspace conversation may message another known exact visible workspace
conversation after boundary authorization; there is no per-conversation opt-in.
Cross-workspace discovery is not provided. Conversations may exchange any number
of handoffs (for example one conversation develops while another verifies), and a
woken run gets no extra turn or token cap; its length is up to the model. Wakeups
are paid runs. Created children keep a persisted parent route for the
`reply_to_parent_conversation` convenience, but may also message any authorized visible
peer. Creator is provenance, not a fixed completion route.

`send_conversation_message` always uses Coordinator; running conversations default to
`steer`, with `follow_up` only by explicit input. A cross-workspace wakeup rebuilds the
target runtime from the target workspace's canonical path, checkout, settings,
permission mode, model catalog, memory, and MCP scope; sender runtime configuration is
never copied. A cross-workspace request carries only a restricted automatic terminal
return route for that exact handoff, not general reverse access.

`create_conversation` may target the current workspace or an exact authorized registered
workspace. In the current workspace, omitting `model` or passing `current` inherits the
caller's effective model; when `reasoning_level` is also omitted, it inherits the caller's
effective reasoning level if that model supports it. Across workspaces, either model form
selects the target workspace's explicit default model and never falls back to the source
model; omitted reasoning uses that target model's default. An explicit model and the
independent `reasoning_level` are validated against the target catalog. The child persists
both selections and uses the target workspace's permission mode.

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
