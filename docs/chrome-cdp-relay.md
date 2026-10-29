# Chrome CDP relay (Phase 0)

Handbean can reuse the user's existing Google Chrome profile without creating a
second browser automation engine. `agent-browser` remains the sole automation
owner; the extension and relay only adapt Chrome's `chrome.debugger` transport
to the browser-level CDP WebSocket that `agent-browser` expects.

## User model

Chrome control has one global switch in **Settings → Computer Control**. It does
not ask for approval on every tab.

While the switch is on:

- ordinary `http:` and `https:` tabs in the current Chrome profile are visible
  to Handbean;
- tabs opened by the Agent are included automatically;
- `chrome:`, extension, DevTools, file, and incognito pages are excluded;
- navigating a controlled tab into an excluded page revokes its debugger
  session;
- Handbean's existing browser action policy still confirms sensitive actions;
- turning the switch off sends one Stop, detaches all debugger targets, closes
  every relay client, and rotates the internal CDP capability.

The Chrome debugging indicator is expected while a tab is attached. The
extension must not attempt to hide it.

## Developer installation

Phase 0 ships as an unpacked extension:

1. Install `agent-browser` 0.39.1 or later. Settings reports the detected
   version, and browser execution fails before launch when an older binary is
   selected.
2. Open `chrome://extensions`, enable Developer mode, and choose **Load
   unpacked**.
3. Select `desktop/chrome-extension` from this checkout.
4. In Handbean, open **Settings → Computer Control** and enable Google Chrome.
5. Copy the pairing URL.
6. Open the Handbean extension popup, paste the URL, and choose **Save &
   connect**.

The pairing URL is a persistent local secret stored in Chrome extension storage
and `~/.handbean/settings.json`. Do not put it in logs, screenshots, bug reports,
or command output. The separate CDP URL is generated in memory on every
Handbean launch and is passed only to the managed `agent-browser` subprocess.

Google Chrome stable no longer honors command-line `--load-extension` in some
builds. Manual loading from `chrome://extensions` is the supported Phase 0
path. Chrome for Testing may still be used for automated acceptance.

## Protocol and boundaries

The relay binds only to `127.0.0.1`: production uses port `17688`, while
`mix phx.server` uses `17699`. Web UI ports are unchanged.
After changing a relay port, copy the new pairing URL into the extension.
To control Chrome from both instances simultaneously, pair separate Chrome
profiles with their respective instances.

```text
browser tool
    → agent-browser --cdp <internal URL> --pin-tab
    → Handbean loopback relay
    → authenticated extension WebSocket
    → chrome.debugger
    → eligible Chrome tabs
```

There are two authenticated WebSocket paths:

- `/extension/<persistent pairing token>` accepts only a Chrome extension
  origin while Chrome control is enabled;
- `/cdp/<ephemeral capability>` rejects browser origins and is available only
  while the extension is connected.

Messages are limited to 1 MiB. Payloads are forwarded as structured JSON and
are never logged. The relay sends a 20-second heartbeat so an MV3 service worker
with an active connection is not reclaimed. A Chrome alarm provides reliable
reconnection after Handbean restarts.

The extension emulates only the browser-level `Target.*` and small `Browser.*`
surface needed to connect `agent-browser`. Page-level CDP commands are passed
through `chrome.debugger`. It contains no selectors, snapshots, click retry
logic, task loop, transcript, or permission store.

## Acceptance performed for Phase 0

The relay has been exercised with an unpacked extension in Chrome for Testing
153 and unmodified `agent-browser` 0.39.1. The following operations completed
through the relay:

- target discovery and automatic attachment;
- navigation to an HTTPS page;
- accessibility snapshot and element references;
- element-reference click;
- form fill;
- screenshot;
- creation and listing of a second tab;
- connection survival beyond the MV3 idle window.

Automated tests additionally verify exclusion of restricted/incognito pages,
revocation after restricted navigation, one-step Stop/detach, and that
`Browser.close` never closes the user's personal Chrome process.

## Deliberate Phase 0 limits

- The extension is not yet published in the Chrome Web Store.
- Pairing is manual once per Chrome profile.
- The relay is desktop CLI only; mobile WebView remains independent.
- Download behavior and the broader browser-level CDP surface are not promised.
- Existing-Chrome attachment does not provide a separate network allowlist.
- The production extension ID is not pinned until Web Store packaging is
  established; the pairing capability remains mandatory.
