# Cross-conversation execution-memory search plan

## Goal

Add an authorized locator over the existing durable conversation trajectory. It
searches persisted execution evidence across conversations and returns stable,
redacted anchors. It does not create another memory store, transcript copy,
runtime, FTS table, embedding index, or source of truth.

```text
search_conversations
  -> bounded redacted hits + conversation/run/turn/sequence/entry anchors
  -> read_conversation / get_conversation_trajectory
  -> Agent synthesis and verification
```

Semantic memory remains owned by `engrams`; execution evidence remains owned by
`conversations`, `conversation_entries`, `conversation_runs`, and
`conversation_turns`.

## Product boundary

- Public owner: `Handbean.Conversations.search_entries/2`.
- Query owner: a ConversationStore module using one joined, workspace-scoped
  projection over canonical tables.
- Tool adapter: deferred `search_conversations`.
- Result: snippets and stable anchors only; never an unbounded transcript.
- Match mode: case-insensitive literal substring, not fuzzy/regex/SQL/FTS syntax.
- Follow-up readers: `read_conversation` and `get_conversation_trajectory`.

## Authorization invariants

- [x] Authenticate the persisted caller before querying `conversation_entries`.
- [x] Caller must be active, `scope == "workspace"`, `visibility == "user"`,
      and its persisted workspace must match trusted runtime context.
- [x] Input cannot provide workspace, visibility, scope, or an authorization grant.
- [x] Joined candidate query restricts targets to active workspace conversations
      with exact caller workspace, workspace scope, and user visibility.
- [x] Free, foreign-workspace, internal/task, pending-delete, missing, and unknown
      visibility records are absent before matching, counts, or snippets.
- [x] An explicit conversation filter is separately authorized before search.
- [x] Excluded classes produce no count, hint, timing-specific error, or “matches
      elsewhere” metadata.
- [x] Only settled public trajectory kinds are eligible; internal/audit and
      streaming/running records are excluded.

## V1 input contract

- [x] `query`: required trimmed UTF-8 literal, 1..200 codepoints.
- [x] `conversation`: optional exact ID, never a title.
- [x] `run_id`: optional durable run ID.
- [x] `kinds`: optional unique list of `user | assistant | tool | system`.
- [x] `tool_name`: optional exact tool-name filter.
- [x] `file_path`: optional literal path substring filter.
- [x] `errors_only`: optional boolean, default false.
- [x] `archived`: `active | archived | all`, default all for execution history.
- [x] `updated_after`: optional inclusive ISO-8601 entry timestamp.
- [x] `limit`: 1..20, default 10.
- [x] `max_chars`: 2,000..16,000, default 8,000.
- [x] `cursor`: optional signed opaque cursor.
- [x] Reject unknown keys and malformed values.

Deferred from V1: regex, SQL/JS, boolean query grammar, model filters, arbitrary
JSON selectors, embeddings, fuzzy search, and raw provider-specific records.

## Result contract

Each result is bounded and includes:

```text
conversation_id
conversation_title
archived
entry_id
sequence
revision
run_id
turn
kind
status
tool_name? / file_path?
created_at / updated_at
snippet (<= 300 Unicode codepoints)
```

- [x] `conversation_id + entry_id + sequence + revision` is the stable entry anchor.
- [x] `run_id + turn + sequence` feeds trajectory inspection.
- [x] Redact and normalize before final match eligibility and snippet creation.
- [x] A query matching only a redacted secret returns no hit.
- [x] Titles/snippets are untrusted evidence, never instructions or authority.
- [x] Do not return total/forbidden/skipped candidate counts.
- [x] Total encoded response respects `max_chars`; tool cap leaves envelope room.

## Ordering and cursor

- [x] Deterministic newest-first order with complete tie-breakers.
- [x] Cursor binds caller conversation/workspace and normalized filters.
- [x] Cursor binds a workspace-authorized conversation/entry revision snapshot.
- [x] Re-check authorization and snapshot on every page; never cache result bodies.
- [x] Any relevant append/edit/delete/visibility/archive change makes the cursor
      stale rather than silently skipping or repeating data.
- [x] Cursor expires after one hour, consistent with existing conversation tools.

## Implementation checklist

### Domain and store

- [x] Harden shared visibility checks to positive `visibility == "user"`.
- [x] Add `Handbean.Conversations.Search` projection/cursor owner.
- [x] Add `Handbean.Conversations.search_entries/2` public entry.
- [x] Add one ConversationStore query owner over canonical storage tables.
- [x] Avoid N+1 conversation/transcript reads.
- [x] Do not add a migration/index for V1; record latency/row-count evidence first.

### Agent tool

- [x] Add deferred `Handbean.Tool.Builtin.SearchConversations`.
- [x] Register it in host tool configuration.
- [x] Add exact schema, error behavior, `max_result_chars`, and prompt description.
- [x] Tell the Agent to follow hits with `read_conversation` or trajectory.
- [x] Keep it out of automatic prompt injection and semantic memory workflows.

### Documentation

- [x] Update `docs/conversation-tools.md` to distinguish title discovery from
      execution-body search.
- [x] Document redaction-before-match, stable anchors, archive default, cursor
      invalidation, and absence of totals.
- [x] Document that search results are evidence locators, not trusted memory.

### Tests

- [x] Missing/forged/free/internal/task caller fails before entry query.
- [x] Foreign/free/internal/pending-delete target sentinels never appear.
- [x] Explicit inaccessible target returns the same non-oracle error.
- [x] User/assistant/system/tool content and filters behave as specified.
- [x] Tool records are bounded/redacted; secret-only queries return no hits.
- [x] Literal `%`, `_`, quotes, slash, Unicode and emoji do not become grammar.
- [x] Stable anchors map back to the same entry/trajectory record.
- [x] Deterministic ties paginate without duplicate/skip.
- [x] Filter/caller/source mutation invalidates cursors.
- [x] Empty authorized result is a successful empty result.
- [x] Deferred registration/discovery/loading and result cap are covered.
- [x] Root compile and focused conversation/tool tests pass.
- [x] Real default-workspace search locates a controlled persisted message/tool
      and then reads the same evidence through follow-up APIs.

## Validation evidence

- `mix compile --warnings-as-errors` passed.
- Conversations domain plus tool adapter: 24 focused tests passed.
- Deferred registry exposure: 1 focused test passed.
- Real `~/.handbean_dev` default-workspace fixture verified:
  - same-workspace assistant and tool evidence located;
  - foreign-workspace and internal evidence excluded;
  - secret-only query returned no result;
  - tool/kind/path/error filters located the expected tool entry;
  - returned entry/run/turn/sequence/revision anchors resolved to the same records
    through `read_conversation` and `get_conversation_trajectory`;
  - deferred tool JSON matched the domain result;
  - all fixture conversations and entries were deleted afterward.
- V1 intentionally has no migration/index. A 5,000 SQL-candidate guard returns
  `search_too_broad`; callers narrow the query with conversation/run/kind/tool/path/time filters.

## Explicit non-goals

- No second database or transcript mirror.
- No `conversation_entries_fts` trigger table in V1; streaming updates would
  amplify writes and SQLite contention.
- No embedding/vector store.
- No synapse or engram integration.
- No automatic session-start execution-history injection.
- No raw SQL/JS query tool.
- No multi-hop synthesis cache or automatic history-to-engram promotion.
