# macOS computer use v1

The AppKit **Handbean.app** owns Screen Recording, Accessibility and event-post
permissions. BEAM never obtains TCC through a CLI helper. Use the existing stable
Developer ID signature for normal installation; ad-hoc rebuilds/`swift run` do
not establish stable TCC identity. This change does not grant permissions,
notarize, deploy or install a new release.

The `computer` tool is injected only into a BEAM process launched by this native
host. An attached existing server does not gain computer use. Use a vision-capable
OpenAI Responses/Codex, Anthropic or compatible Chat Completions model. Unsupported
models cannot be assumed to understand the images. Tool calls are ordinary Agent
loop calls, not OpenAI's private desktop backend or a second agent runtime.

`list` returns app/window IDs and three permission facts. `select` requires runtime
approval bound to those arguments, then a separate native app/window approval.
`observe` captures only the selected window without focus. `click`, `type`, `key`
and `scroll` consume a one-use observation (30 seconds) and require **Allow once**
in an AppKit dialog showing exact arguments. Workspace auto/yolo, remembered rules
and auto-review cannot bypass that native gate. Foreground activation is explicit;
no background input or private SkyLight API is promised. Every input requires
confirmation, including data transmission, purchases, deletion and other sensitive
actions; there is no prompt-only consequential-action classifier.

**Pointer acceptance is incomplete.** Normal `click`/`scroll` return
`unsupportedPointer` without dispatch. The fixture-only verification host has
two explicit modes. `pointer_probe: true` sends public AppKit-constructed events
tagged for receive-and-suppress diagnostics. `pointer_acceptance: true` uses the
same production event path but may change only the disposable fixture after a
native confirmation. Neither flag is accepted by the production host. The old
CG route reached the fixture process but had no AppKit window association. The
new public factory preserves the window number in construction probes; normal
applications stay disabled until the acceptance mode proves both the target
control and scroll content actually change. Type/key remain available.

The native host owns one global conversation/run lease. Windows bind bundle ID,
PID/start time, CG window ID, title and bounds; moved, resized, closed, ambiguous
or expired windows fail closed. Coordinates refer to returned image pixels, then
map to global logical points (including Retina and negative monitor origins).
Input verifies AX focus/window and rejects sheets, secure fields, terminals,
Handbean, system/security/password apps and known terminal-capable IDEs. Events
are PID-routed using public APIs and never posted to the global HID tap. macOS
does not acknowledge delivery: results say `side_effect: unknown`, return another
observation and forbid blind input retries. User movement/content can still race
native calls; stay present. This is not a security sandbox for arbitrary programs.

Stop from the native floating panel, Handbean menu **Stop Computer Use**, runtime
Stop, EOF, or timeout invalidates the lease generation. Cancelled run IDs are
retired beyond the maximum request deadline; a late request cannot reacquire it.
No locked-screen operation or concurrent controllers.

Tool images are limited to 5 MB each and two per result. Files are mode 0600 under
`Host.data_dir()/.handbean/tool-images/<conversation>/<uuid>.<ext>`; transcript,
Session and history hold only bounded MIME/size/SHA256/opaque references. Provider
encoding reads and validates those files at the wire boundary. Only the two most
recent tool images are retained for model context, including restored history;
compaction discards old images and estimates 6,000 tokens per retained image.
Historical observations restore as assistant tool calls + tool results, not user
authorization. Missing/tampered references become explicit notices. Image files
currently persist with local history (no automatic retention cleanup); remove the
conversation's tool-images directory to remove its images. Screenshots may contain
sensitive data and are sent to the selected model provider.

## Reproducible native acceptance, disposable app only

First compile (cwd `desktop/macos`):

```bash
swift test --scratch-path ../../.amp/in/computer-use-swift
```

From the repository root, create a private fixture directory, build the test app,
and launch it. This app has a text field, click counter and scroll area. It never
opens existing documents, launches tools or accesses user files:

```bash
VERIFY_DIR="$(mktemp -d /tmp/handbean-computer-verify.XXXXXX)"
chmod 700 "$VERIFY_DIR"
bash desktop/macos/scripts/build_computer_fixture.sh "$VERIFY_DIR"
open -n "$VERIFY_DIR/ComputerFixture.app" --args "$VERIFY_DIR/report.json"
# Use the just-built executable or, preferably, a consistently signed app bundle.
desktop/macos/.build/debug/Handbean --computer-use-verification "$VERIFY_DIR"
```

Use a second terminal for commands below. The verification flag starts **only**
the actual native bridge, with a hard restriction to `com.youfun.computerfixture`.
No BEAM or production storage starts. It writes launch credentials to mode-0600
`bridge.json`; never publish that file. It cannot waive TCC or click Allow for you.
If using the scratch build above, get the binary path with
`swift build --scratch-path ../../.amp/in/computer-use-swift --show-bin-path` from
`desktop/macos`, and use that `Handbean` path instead.

For a private App with repeatable TCC identity, package the compiled binary and
the fixture directory using the helper below. Keep the same bundle path and
signing identity between builds. The default ad-hoc signature is for disposable
testing; it does not promise stable permissions. This does not install or launch
the App or grant any permission:

```bash
bash desktop/macos/scripts/build_computer_verification.sh /absolute/path/to/Handbean "$VERIFY_DIR" 'YOUR_TEST_SIGNING_IDENTITY'
open -n "$VERIFY_DIR/ComputerVerification.app"
```

Only `com.youfun.handbean.computerverification` reads the private Info.plist
`HandbeanComputerVerificationDirectory`. It remains fixture-only after System
Settings **Quit & Reopen**, without command-line flags. Missing/invalid private
configuration terminates instead of starting the normal backend. The directory
must exist, belong to you and be mode 700; normal Handbean ignores this plist key.

```bash
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" list
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" select --window WINDOW_ID
```

Expected: `screen_recording`, `accessibility`, `event_post` reflect **this host**.
Missing permissions are a blocker; do not automatically grant them or drive System
Settings. `select` displays the app/window authorization sheet; manually approve
only the fixture. It returns an observation ID, actual pixel width/height and a
saved PNG. Inspect the PNG. Copy coordinates from that image rather than guessing
screen/Retina values. Each successful action returns a new ID:

```bash
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" click --pointer-probe --receipt RECEIPT --x X --y Y
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" type --receipt NEW_RECEIPT --text cua-test-42
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" key --receipt NEW_RECEIPT --key tab
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" scroll --pointer-probe --receipt NEW_RECEIPT --x X --y Y --delta-y -120
cat "$VERIFY_DIR/report.json"
```

Approve each native confirmation manually. Verify `report.json` exact text and
counter, plus changed screenshot/scroll rows. The report also retains the last
128 fixture-local input events: event type, window number, window-local/Quartz
coordinates, public routing fields, click state/event number and timestamps.
`scroll_origin` verifies actual content movement. This monitor never manufactures
or approves input. Ordinary input carries the public `eventSourceUserData` tag
`0x484243554131` ("HBCUA1"); the report records it and the source PID. Correlate
that tag with time/window/coordinates to distinguish this host's events from
manual input, not cursor movement or counter alone. This tag is not secret or
an authorization check, and arbitrary apps can forge it.

Pointer probes instead carry `0x484250524F42` ("HBPROB"). The fixture returns
`nil` from its local monitor for those events, before controls receive them.
Require `selected_window: true` (the actual `event.window === fixture.window`),
the expected window-base point, `hit_counter_button`/`hit_scroll: true` (including
descendant views) and `suppressed_probe: true`. Clicks/text/scroll origin must stay
unchanged. A nonzero window number or matching coordinate alone does not pass.
CG global location can differ in the sending process; do not change it with the
CG location setter, which breaks AppKit local annotation in construction probes.
After successful receive diagnostics, run an independently approved harmless
control action before normal pointer input can be enabled.

Request a new observation and run the fixture-only control acceptance. These
commands still show an exact native confirmation and cannot select another app:

```bash
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" click --pointer-acceptance --receipt RECEIPT --x X --y Y
python3 desktop/macos/scripts/computer_verify.py "$VERIFY_DIR" scroll --pointer-acceptance --receipt NEW_RECEIPT --x X --y Y --delta-y -120
cat "$VERIFY_DIR/report.json"
```

Require `control_acceptance: true`, `selected_window: true`, the expected hit
target, an incremented `clicks` value for click, and a changed `scroll_origin`
for scroll. Inspect the returned screenshots as an independent visual oracle.
A received event without the corresponding control/content change does not pass.
Production `click` and `scroll` remain disabled until this acceptance is recorded
on a signed verification host with the real macOS permissions.

Record one confirmation panel and one observed fixture screenshot; inspect both,
never expose credential files.
If the request reports unknown side effects, **observe** before another action.

Failure acceptance:

* Replay a consumed receipt, move/resize the fixture, or wait 30 seconds: input
  must be refused and the counter/text unchanged.
* While one session owns the fixture, select with `--session other-run`: busy,
  no second approval or input. Other-session stop does not release the owner.
* Start `select --session eof-run --disconnect-after 2`; while approval is open,
  EOF must dismiss it and invalidate that session. Do not click Allow.
* Start `select --session deadline-run --deadline-ms 2000`; let its confirmation
  expire. No later input. Only the fixture is eligible.
* During input confirmation, click native **Stop Computer Use**, or send `stop`
  from another terminal using the same session; no queued input can run after it.
  A new run needs a new `--session` value.
* Authentication/request association: an invalid credential is disconnected;
  responses must match their request ID. The client validates correlation.

Quit both native processes before deleting this disposable directory. No shared
data or existing windows should be modified during acceptance.

## Linux shared-runtime checks (not macOS acceptance)

```bash
HANDBEAN_PUBLIC_BIND=0 mix test --include e2e test/handbean/e2e/computer_use_test.exs
HANDBEAN_PUBLIC_BIND=0 mix test test/handbean/tool/builtin/read_test.exs test/handbean/tool/builtin/browser_test.exs
```

Use a separate process-level HOME for the test suite. FakeProvider asserts real
approval lifecycle, durable tool/image transcript and terminal state. It does
not prove native screenshot, input, TCC or UI rendering on macOS.
