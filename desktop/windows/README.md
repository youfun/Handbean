# Handbean for Windows

Native shell around the Handbean Web UI. The window is a WebView2 (the Edge
runtime Windows ships with) pointed at the bundled Phoenix server. There is no
Electron, Chromium, or CEF, and no address bar, tabs, or bookmarks.

Windows 10 or 11 (x64). A machine needs the WebView2 Evergreen runtime, which
Windows 11 includes; the shell checks at launch and points to the download page
when it is missing. The app does not need Elixir or Node installed.

## Layout

```
desktop/windows/
  go.mod, mygo.json         Go module and mygo configuration
  main.go                   single instance, lifecycle, window
  internal/core/            port, navigation, and launch decisions (tested)
  internal/backend/         backend process lifecycle
  internal/shell/           paths, logging, window
  resources/icon.png        executable icon (from priv/static/favicon.ico)
  resources/handbean-web/   unpacked release (not committed)
  scripts/fetch_web_release.ps1
  scripts/build_app.ps1
```

The package layout mirrors the macOS app bundle:

```
Handbean-windows-amd64.zip
  Handbean.exe
  handbean-web/             bin/handbean.bat, erts-*, lib/, releases/
```

## Process lifecycle

`bin/handbean.bat start` stays in the foreground. The shell invokes it through
`cmd.exe /d /s /v:off /c` using a fixed path relative to the release directory,
and keeps the command interpreter's PID. The installation path is passed as the
working directory rather than interpolated into a shell command.

1. Unless `HANDBEAN_PORT` or the stored preference (`config.json` in the user
   data directory) specifies a port, ask the kernel for an unused loopback
   port. This avoids the Web UI's default port 5008.
2. Probe the selected port. If `HANDBEAN_PORT` (or an explicit constructor
   port) already has a Handbean server (the `/desktop-health` endpoint),
   attach. A port stored only in `config.json` is used to spawn, not to
   attach. Quit does not signal an attached process. The window title
   shows「已附著」only when attached.
3. If nothing is listening, start `resources/handbean-web/bin/handbean.bat`.
   Stdout/stderr go to `backend.log` in the log directory.
4. Wait until the port answers, then load the page. Website data is the
   default persistent store; the shell never clears it.
5. On Quit (or closing the last window), stop the backend this process
   spawned through `bin/handbean.bat stop`, reusing its launch environment.
   The RPC command and graceful exit share an 8-second deadline, followed
   by bounded `taskkill /T /F` cleanup if needed. An attached server is left running.

The owned backend has a per-port Erlang node name at `127.0.0.1` and a fresh
random distribution cookie on each spawn. Its distribution listener binds IPv4
loopback only. `ERL_EPMD_ADDRESS=127.0.0.1` also requests loopback binding when
starting EPMD; an EPMD daemon already running keeps its existing binding. The
cookie is passed to the stop command through the inherited launch environment,
not command-line arguments or logs.

The server binds `127.0.0.1` only. Phoenix `check_origin: true` compares the
page host with `PHX_HOST`, not the scheme or port. A server this app starts
gets `PHX_HOST=127.0.0.1` and the web view loads `http://127.0.0.1:<port>/`.

The app and `start.bat` both use `~/.handbean/handbean.db`, the same default
as the release. `SECRET_KEY_BASE` is reused from the environment when set,
otherwise stored at `~/.handbean/secret_key_base` so cookies survive
restarts. The file is written with Unix mode 0600; on Windows that does
not replace the parent directory ACL.

Links that leave the Handbean origin open in the system browser; the shell
does not navigate its main frame to arbitrary URLs. `target="_blank"` and
`window.open()` open in the system browser as well.

Phase 1 quits when the window closes. No tray, notifications, or auto-update
yet.

## Build

From the repository root, build the current source and package the complete
native client:

```powershell
powershell scripts/windows/build_gui.ps1
```

This writes `handbean-web-windows-amd64.zip` (the plain Web UI package) and
`desktop/windows/Handbean-windows-amd64.zip` with its SHA-256 file.

To build the shell around a published Web release instead:

```powershell
cd desktop/windows
powershell scripts/fetch_web_release.ps1 web-latest
# or: $env:HANDBEAN_WEB_ZIP = "path/to/handbean-web-windows-amd64.zip"; powershell scripts/fetch_web_release.ps1
powershell scripts/build_app.ps1
```

`go test ./...` covers the pure decisions in internal/core. `go run .` starts
the shell from source; it can attach to a server you already started.

GitHub Actions workflow `.github/workflows/desktop-windows.yml` is
`workflow_dispatch` only. It builds an unsigned zip artifact.

## Check

1. Keep an existing `start.bat` running on port 5008 if desired.
2. Run `Handbean.exe`. It should choose a different loopback port, show the
   Handbean UI, and connect LiveView.
3. Quit the app and confirm its listener is gone while the Web UI on port
   5008 is still running.
4. To test attachment explicitly, launch with `HANDBEAN_PORT=5008`. The title
   should say「已附著」; quitting the app must leave the manual server running.

Logs: `backend.log` and `shell.log` in the log directory
(`%AppData%\Handbean\logs`).

If the app crashes, the backend can keep running (Windows has no PDEATHSIG).
That orphan is not killed on the next launch. Stop it with the pid file
written only for a server this app spawned:

```powershell
taskkill /PID (Get-Content "$env:AppData\Handbean\backend.pid") /T /F
```

## Limits

- Phase 1 does no storage-lock PID arbitration: the lock is a NIF flock with
  no PID payload, and Windows has no lsof. A busy database surfaces as a
  backend boot failure with the log tail on the error page.
- Subframe (iframe) navigations are not distinguished: the navigation policy
  covers the main frame; same-origin frames such as the LiveView preview work.
- One bundled server per port. A second app attaches; only the process that
  spawned the server stops it.
- Workspace files are read by the OTP child, not by the web view.
- The in-browser terminal uses the same WebView2 the page gets. If a page
  needs a browser-only API, use the system browser for that link; the shell
  will not become a general browser.
- The executable icon is the 48x48 favicon for now; replace
  `resources/icon.png` with a 1024x1024 render of the logo for release.
- The package is unsigned, so SmartScreen warns on first run. Code signing
  (mygo `windows.certificate` or `signCommand`) is a later phase.
- No auto-update. Menu bar mode is not implemented yet.
- Keep-awake is not enabled. Closing the window quits.
