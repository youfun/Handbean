# Handbean for macOS

Native shell around the Handbean Web UI. The window is a `WKWebView` pointed at the bundled Phoenix server. There is no Electron, Chromium, or CEF, and no address bar, tabs, or bookmarks.

macOS 15 or later on Apple Silicon (`arm64`). The minimum version follows the bundled OTP runtime. The app does not need Elixir or Node installed.

## Layout

```
desktop/macos/
  Package.swift
  Sources/Handbean/          AppKit shell, WKWebView, backend process
  Sources/HandbeanCore/      URL, navigation, and launch decisions (tested)
  Resources/Info.plist
  Resources/Handbean.icns
  Resources/handbean-web/    unpacked release (not committed)
  scripts/fetch_web_release.sh
  scripts/build_app.sh
```

`Handbean.app`:

```
Contents/MacOS/Handbean
Contents/Info.plist
Contents/Resources/handbean-web/    bin/handbean, erts-*, start.sh
```

## Process lifecycle

`bin/handbean start` stays in the foreground (`exec` elixir `--no-halt`). The shell launches it with `/bin/sh` and keeps that PID.

1. Unless `HANDBEAN_PORT` or UserDefaults `HandbeanPort` specifies a port, ask macOS for an unused loopback port. This avoids the Web UI's default port 5008.
2. Probe the selected port. If an explicitly configured port already has an HTTP server, attach. Quit does **not** signal that process. The window title shows「已附著」.
3. If nothing is listening, start `Contents/Resources/handbean-web/bin/handbean` (or `HANDBEAN_WEB_ROOT`). Stdout/stderr go to `~/Library/Logs/Handbean/backend.log`.
4. Wait until the port answers, then load the page. Website data is the default persistent store; the shell never clears it.
5. On Quit (or closing the last window, phase 1), SIGTERM the PID this process spawned, wait up to 8 seconds, then SIGKILL. An attached server is left running.

The server binds `127.0.0.1` only. Phoenix `check_origin: true` compares the page host with `PHX_HOST`, not the scheme or port. A server this app starts gets `PHX_HOST=127.0.0.1` and the web view loads `http://127.0.0.1:<port>/`. An attached `./start.sh` defaults to `PHX_HOST=localhost`, so the page is `http://localhost:<port>/` (or whatever `PHX_HOST` is on that process). A non-loopback host is ignored.

The app and `./start.sh` both use `~/.handbean/handbean.db`, the same default as the release `bin/handbean` via `rel/env.sh.eex`. `SECRET_KEY_BASE` is reused from the environment when set, otherwise stored at `~/.handbean/secret_key_base` (mode 0600) so cookies survive restarts. The app disables BEAM distribution because it owns the foreground child process directly and does not need an additional network listener.

Links that leave the Handbean origin open in the system browser. The shell does not navigate its main frame to arbitrary URLs. There is no App Sandbox: the bundled server must bind localhost and read the workspace. Turning the sandbox on would need extra file and network entitlements and would still not cover every folder the tools touch.

Phase 1 quits when the window closes. `MenuBarController` is a stub for a later `NSStatusItem` menu (pinned/recent threads, keep-awake, Open Handbean). That phase should keep the backend alive until Quit.

A backend this app spawns gets a loopback notification bridge. A finished reply is posted with `UNUserNotificationCenter` as `com.youfun.handbean`, including while the window is frontmost, unless that conversation is the one on screen. Clicking it opens the conversation. Browser toasts and the Android notifier are unchanged. An attached server is not given the bridge. Launch asks for notification permission; a denial is left denied.

## Build

From the repository root, build the current source and package the complete native client:

```bash
bash scripts/build.sh
```

This writes `desktop/macos/build/Handbean.app`, `Handbean-macos-arm64.zip`, and its SHA-256 file. The intermediate OTP release stays under `desktop/macos/build/handbean-web`; it does not overwrite an installed release in `~/Library/Application Support`.

To build the shell around a published Web release instead:

```bash
cd desktop/macos
bash scripts/fetch_web_release.sh web-latest
# or: HANDBEAN_WEB_TARBALL=/path/to/handbean-web-macos-arm64.tar.gz bash scripts/fetch_web_release.sh
bash scripts/build_app.sh
open build/Handbean.app
```

`swift test` and `swift run` work without a bundle. `swift run` can attach to a server you already started; it cannot see `Resources/handbean-web` unless you set `HANDBEAN_WEB_ROOT`.

`build_app.sh` signs ad-hoc so the app opens on this Mac. That signature is not notarized, and a downloaded copy is stopped by Gatekeeper. A release zip has to be signed with a Developer ID Application certificate and notarized:

```bash
bash scripts/build.sh
bash desktop/macos/scripts/notarize_app.sh
```

The script signs every Mach-O inside the bundle with Hardened Runtime, uploads the zip to `notarytool`, staples the ticket onto `Handbean.app`, and rewrites `Handbean-macos-arm64.zip`. Upload that second zip. The first zip, produced before stapling, does not carry the ticket.

Apple Distribution certificates cannot be used for this. Create a Developer ID Application certificate and store a notarytool keychain profile named `handbean-notary` first; the script prints the exact commands when either is missing. Entitlements are `desktop/macos/entitlements.plist` (JIT and bundled NIFs). The app stays outside the App Sandbox, which is what lets it read a workspace.

GitHub Actions workflow `.github/workflows/desktop-macos.yml` is `workflow_dispatch` only. It builds an ad-hoc zip artifact; it does not notarize.

## Check

1. Keep an existing `./start.sh` running on port 5008 if desired.
2. Double-click `Handbean.app`. It should choose a different loopback port, show the Handbean UI, and connect LiveView.
3. Quit the app and confirm its listener is gone while the Web UI on port 5008 is still running.
4. To test attachment explicitly, launch with `HANDBEAN_PORT=5008`. The title should say「已附著」; quitting the app must leave the manual server running.

Logs: `~/Library/Logs/Handbean/backend.log` and `shell.log`.

If the app crashes, the backend can keep running (macOS has no `PDEATHSIG`). That orphan is not killed on the next launch. Stop it with the pid file written only for a server this app spawned:

```bash
kill "$(head -n 1 "$HOME/Library/Application Support/Handbean/backend.pid")"
```

## Limits

- One bundled server per port. A second app attaches; only the process that spawned the server stops it.
- Workspace files are read by the OTP child, not by the web view. Protected folders (Desktop, Documents, Downloads) can still raise macOS privacy prompts for that child.
- The in-browser terminal uses the same WebKit the page gets. If a page needs a browser-only API, use the system browser for that link; the shell will not become a general browser.
- No auto-update. Direct download uses `scripts/notarize_app.sh`; menu bar mode is not implemented yet.
- Keep-awake is not enabled. Closing the window quits.
