# Error diagnostics JSON

Settings → Advanced → Error diagnostics downloads `handbean-error-diagnostics.json`.
The default is the last 7 days and currently unresolved errors; 24 hours, 30 days,
all retained history and all statuses are also available. Downloading does not
upload, resolve, mute or otherwise change errors. This is an application-wide
report for the host's single authorized user, using the existing loopback or
password/session access boundary. Responses use `Cache-Control: no-store`.

## Schema version 1

`schema_version` is an integer; `exported_at` and all timestamps use UTC ISO-8601.
`application` contains the app version, OS family/name, Elixir and OTP versions.
No hostname, username, machine ID, runtime arguments or configuration is included.

`filters` records the chosen range and current status, and inclusive `since` and
`until` occurrence timestamps. `since: null` means all retained history. Counts
reflect **retained occurrences within these bounds**, not lifetime error counts.
Status is the group's current status, not its historical status at occurrence time.
Muted groups are included. Groups with no matching occurrences are excluded.

`counts.matching_groups` and `matching_occurrences` describe the full filtered
result before output limits. `exported_groups` and `exported_occurrences` describe
what is present in this file. `limits` is currently 100 groups, 3 recent occurrences
per group and 30 frames per occurrence. `truncated` is true if any matching groups,
occurrences or stack frames were omitted by those limits. These limits bound the
output; aggregate counts still read the matching database history.

Groups sort by their latest matching occurrence (descending), with database ID as
a deterministic internal tiebreaker. Occurrences sort by time then ID, descending.
Database reads occur in a transaction. Export IDs such as `error-1` are local to
this file; database IDs, fingerprints and conversation/workspace IDs are omitted.

Each `errors` entry contains `kind`, current `status`, `muted`, fixed-template
`summary`, latest sampled `failure_class`, `reason_category`, `tool`, first/last
matching occurrence times, `occurrence_count`, `exported_occurrence_count`,
`truncated`, and `occurrences`. Classification may differ between occurrences.

Each occurrence contains time, allowlisted classifications, optional `provider_ref`
and `model_ref`, `omitted_classification_fields`, `stack`, and `stack_truncated`.
Provider/model references are keyed pseudonyms: identical recorded identifiers
correlate within one export, but a new random HMAC key is used for every export and
never included. Original custom names, model identifiers, provider URLs and hosts
are not exported. Missing, non-string or oversized identifiers become null.
These references do not directly reveal the original identifiers; external knowledge
may still associate a reference with a provider. Timestamps and stacks can also
correlate occurrences across files despite key rotation.

## Privacy and interpretation

The export constructs a new allowlisted document rather than serializing database
records. `ErrorTrackerFilter` / `Handbean.Log.Redactor` still sanitize the selected
classification fields, but regex redaction is not the privacy boundary. Class,
category and tool values must match fixed known values or static builtin tool
metadata; otherwise they become null. This is an export policy, not a new error
classifier. `omitted_classification_fields` names rejected, non-null fields.
`privacy.original_message_count` reports sampled original messages omitted.

Original reasons are **always omitted** because they may contain chat, prompts,
provider responses, file contents or credentials. Summaries explicitly say this
and never claim a reconstructed cause. Arbitrary context, request/event parameters,
tool inputs/outputs, breadcrumbs, user paths and credentials are omitted.

Stack modules must belong to the explicit shipped-application allowlist. Functions
and arities must match trusted BEAM export/local function tables; if unavailable,
only exported functions survive. Source paths must match both the module's compile
source and the build-time project `lib/**/*.ex` manifest, relative to the known
project source root. Dependency source paths and unverified locations are null.
Arguments are never included. Unknown fields are null, while frame order and safe
code symbols/line numbers remain useful to developers.

This file supports frequency, timing, code-location and within-file model/provider
correlation analysis. It is intentionally insufficient to reconstruct conversations,
raw provider failures or arbitrary original error messages. Empty results are valid.
New failures may arise after the snapshot; old failures may already have been pruned.
