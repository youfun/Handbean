# Handbean

[English](README.md) · [中文](README.zh.md)

A local agent assistant for autonomous coding. Conversations, tool execution, and long-term memory stay entirely on your machine. The Phoenix LiveView Web UI and native mobile clients (Android and iOS) share the exact same Elixir/OTP runtime core. The project was formerly named **Handbeam**.

- **Workspace control**: Read, edit, and write files, run a shell, fuzzy-search filenames, and locate code positions by symbol or embeddings
- **Granular permissions**: Fine-grained workspace permission policies (auto, prompt, or deny)
- **Streaming & observability**: Real-time response streaming with live tool execution status
- **Broad provider support**: Anthropic and OpenAI-compatible endpoints (StepFun, Ollama, OpenCode Go, DeepSeek, OpenRouter, and more)
- **Extensible runtime**: MCP (Model Context Protocol), [workspace Elixir extensions](docs/extensions.md), BEAM VM introspection, and cross-session memory
- **Unified architecture**: Android, iOS, and Web all run on the same Coordinator and Runner lifecycle

## Inline HTML / interactive widgets (Web)

Ask for a visualization, calculator, or small interactive UI in Web chat. Assistant
`html` / `widget` fences render inline with streaming static previews, source view,
and copy. Inline JavaScript runs after the closing fence. History stays Markdown;
reopening restores previews, not transient input state.

An iframe sandbox without `allow-same-origin` isolates application DOM, cookies,
storage, and host tools. CSP blocks external scripts, fetches, and form submissions;
widgets must be self-contained, without CDN dependencies. This is not an OS-level
or fully network-isolated sandbox: frame navigation remains governed by browser
rules. Android / iOS native chat still displays code, without inline previews.

## App screenshot

Native Android chat interface, captured on a physical device:

<img src="docs/screenshots/android-chat-en.png" alt="Handbean Android chat screen in English" width="360">

### On-device Elixir projects (experimental)

Create, edit, test, and run Elixir/Mix projects directly on your phone through natural dialogue. The agent uses the app's bundled Elixir/OTP runtime via `mix_project` without requiring a separate Linux environment or chroot:

- **Dependency support**: Supports pure Elixir/Erlang dependencies compatible with the bundled host version. C extensions (NIFs) and external toolchains are rejected.
- **Execution environment**: Code runs inside the app's BEAM VM. It is not an isolated sandbox; only run code you trust.
- **Platform status**: End-to-end chat workflows are verified on physical Android devices. iOS is currently verified in the simulator only.

## Web UI standalone packages

Prebuilt packages with a bundled OTP runtime are available on GitHub Releases under `web-latest` and version tags. Extract and run without installing Elixir:

| Platform / Architecture | Package | How to run |
|---|---|---|
| Linux (x86_64) | `handbean-web-linux-x86_64.tar.gz` | Run `./start.sh` |
| Linux (ARM64) | `handbean-web-linux-arm64.tar.gz` | Run `./start.sh` |
| macOS (Apple Silicon) | `handbean-web-macos-arm64.tar.gz` | Run `./start.sh` |
| macOS (Native WebKit App) | `Handbean-macos-arm64.zip` | Launch `Handbean.app` (native WebKit shell, zero Electron overhead) |
| Windows (x86_64) | `handbean-web-windows-amd64.zip` | Run `start.bat` |
| Windows (with toolchain, experimental) | `handbean-web-windows-amd64-toolchain.zip` | Prepend bundled Elixir, Mix, Hex, Rebar3, and MinGit to process `PATH` |

**Notes**:
- **Default address**: Standalone release packages serve on `http://localhost:5008`.
- **Windows terminal**: The in-browser terminal is omitted on Windows because Ghostty lacks a Windows native NIF.
- Windows ARM64 builds are not currently published.

### LAN access

Step-by-step Windows / Linux / macOS notes: [LAN deployment](docs/lan-deployment.md)
(Chinese).

The default launcher accepts connections only from this machine. To allow other
devices on a trusted LAN, pass the server's hostname or IPv4 address (not the
client's address):

```bash
# Linux / macOS, from the extracted Web UI package
./start.sh --lan 192.168.1.10
```

```powershell
# Windows, from the extracted Web UI package
.\start.bat -LanHost 192.168.1.10
```

The launcher displays Chinese and English reminders to set a long, random, unique
strong password, then prompts without echoing it. The reminders also appear when
a password is supplied through the environment. The username defaults to
`handbean`; set `HANDBEAN_ACCESS_USERNAME` to override it. For unattended startup,
supply `HANDBEAN_ACCESS_PASSWORD` through the host environment instead. No password
is saved by the launcher. Open `http://192.168.1.10:5008` on the other device and
allow the chosen port through the server's firewall if needed; `PORT` overrides 5008.

LAN mode explicitly enables all-IPv4 binding, password authentication, and HTTP.
HTTP does not encrypt passwords, sessions, or traffic: use this mode only on a
trusted network. Internet-facing deployments need a TLS reverse proxy; do not use
the LAN flag for them. HTTPS enforcement and origin checking remain enabled by
default. See [deployment security](docs/security.md).

## Run from source

### Prerequisites
- **Elixir**: `>= 1.20.0`
- **Erlang/OTP**: `28+`
- **Node.js**: `24` (LTS, for asset bundling)
- **Zig**: `0.16.0` on Linux/macOS, plus **patchelf** on Linux, for the forked Ghostty terminal engine and NIFs. `mix compile` builds the engine pinned by the dependency automatically; the first build downloads Ghostty sources and Zig dependencies.

### Setup & run

```bash
# 1. Configure model credentials (specify apiKey or export OPENAI_API_KEY)
cp models.example.json models.json

# 2. Install dependencies and build assets
mix setup

# 3. Start development server (serves on http://localhost:5002)
mix phx.server
```

Open `http://localhost:5002` in your browser and select a workspace directory to begin.

### Build and run a production Web UI

On Linux or macOS, choose the target matching the build machine
(`linux-x86_64`, `linux-arm64`, or `macos-arm64`):

```bash
bash scripts/pack_webui.sh linux-x86_64
bash scripts/start.sh                     # local access only
# Or, instead of the previous command:
bash scripts/start.sh --lan 192.168.1.10   # trusted LAN, prompts for a password
```

On Windows:

```powershell
.\scripts\build_webui.bat                 # build and select a new local version
.\start.bat                               # local access only
# Or, instead of the previous command:
.\start.bat -LanHost 192.168.1.10
```

On Windows, `scripts\build_webui.bat` (or `build_webui.ps1`) is the one-click
local build: it checks the toolchain (Elixir/Mix, Node.js, tar, MSVC cl/nmake),
prints a bilingual error with install hints when something is missing, loads the
MSVC environment, and then runs the same `pack_webui.ps1` that CI uses. Every
successful local build gets its own directory under `_build/local-webui/versions`;
only `_build/local-webui/current.txt` is changed. A Web UI already running from an
older directory is therefore never overwritten. Stop it and run the repository
root `.\start.bat` again to activate the newly selected build. The launcher keeps
a compatibility fallback for old `_build/prod/rel/handbean` builds.

Extracted packages still run the release beside `start.sh` / `start.ps1`. Neither
launcher starts a development server. The root launcher forwards arguments such as
`-LanHost`.
Production data defaults to `~/.handbean/handbean.db` (`%USERPROFILE%` on Windows);
`DATABASE_PATH` can override it. The workspace index defaults to `workspaces.json`
beside that database (`HANDBEAN_WORKSPACES_FILE` overrides). Do not run GUI and
Web UI against that database at the same time.

### Asset development

- Frontend source files live in `assets/`. Compiled bundles in `priv/static/assets/` are not committed to git.
- Styles are organized under `assets/css/`, with baseline styles in `assets/default.css`.
- `mix setup` installs dependencies and builds assets. To build assets alone, run `mix assets.setup` followed by `mix assets.build`.
- `mix phx.server` automatically watches frontend files and recompiles them on change. For production builds, `mix assets.deploy` minifies assets and generates digests.
- `mix compile` compiles Elixir source code only.

### Running tests

```bash
mix test --exclude slow --exclude e2e
```

## Migrate existing data

When upgrading from Handbeam, use [the migration script](scripts/MIGRATION.md) to copy configuration, the workspace registry (preserving conversation associations), and the production database into the new locations. Preview with `python3 scripts/migrate_legacy_data.py`, then run with `--apply`. Existing destinations and original files are preserved.

## Inspect effective host configuration

Inspect your resolved runtime configuration safely without booting the full server, initializing file stores, resolving credentials, or connecting to MCP servers:

```bash
mix handbean.inspect_config --workspace /path/to/workspace
```

Within a running host session, call `Handbean.ConfigInspection.report(workspace: path)`.

**Key features**:
- **Layered decision breakdown**: Separates Host seed capabilities, registered tool membership, passive dependency checks, and runtime authorizations.
- **Precedence hierarchy**: Global settings override defaults; workspace settings override global settings; runtime provider environment variables take precedence over catalog values.
- **Automatic redaction**: Automatically suppresses absolute filesystem paths, model identifiers, permission patterns, dynamic tool names, endpoints, secrets, and prompt text for safe sharing.
- **Non-intrusive diagnosis**: Pure static analysis. Does not execute external commands, native callbacks, or live network probes.

## ChatGPT / Codex subscription login

If you have a ChatGPT subscription with Codex access, you can sign in directly without setting up prepaid API credits:

1. In Web UI, navigate to **Settings → Available models → Subscription login** and select **ChatGPT (Codex subscription)**.
2. Enter the device code on the OpenAI verification page, then pick a model from this provider.
3. Use the **Refresh subscription models** button to update the model catalog.

**Details**:
- No Codex CLI required. Inference connects directly to the Codex Responses backend; Handbean handles tool execution and permission prompts.
- Uses your ChatGPT Codex subscription allowance, not Platform API credits. Available models and rate limits are dictated by your account plan.
- Auth credentials are stored locally in `~/.handbean/auth.json` (mode `0600`). Never share or commit this file.
- The native mobile settings UI does not currently support device login.

## Private Git repository authentication

The `git` tool takes a named credential reference (`credential`), never raw tokens or passwords.

Configure credentials in the trusted host at startup rather than in workspace settings or chat messages. For example, in host runtime configuration:

```elixir
config :handbean, :git_credentials, %{
  "project-origin" => [
    endpoint: "https://github.com",
    password: System.fetch_env!("PROJECT_GIT_TOKEN")
  ]
}
```

The agent invokes the tool with:
```json
{"action": "push", "credential": "project-origin"}
```

**Security boundaries**:
- Fresh authentication challenges must match the configured HTTPS endpoint.
- libgit2 rejects cross-host redirects and HTTPS downgrades, but may reuse credentials across other ports or paths on the same hostname.
- **Configuring credentials trusts all HTTPS services on that hostname**; it does not isolate by port or repository path. Avoid configuring credentials for hosts serving untrusted tenants, and prefer repository-scoped, least-privilege tokens.
- Omit `credential` for anonymous read access. Mobile hosts can inject the same startup configuration.

## Mobile development (Android + iOS)

```bash
cd mobile
mix deps.get
mix test

# Build Android APK
bash script/pack_android_apks.sh --abi arm64-v8a

# Launch iOS Simulator (requires macOS and Xcode)
mix ios.native
```

See [`mobile/README.md`](mobile/README.md) for full instructions. Use `--abi x86_64` on ChromeOS. The iOS test app Bundle ID is `com.example.handbean_probe`.

## License

Source and non-iOS builds are licensed under [FSL-1.1-ALv2](LICENSE). Copyright (C) 2026 youfun.

iOS builds that statically link [ish-arm64](https://github.com/youfun/ish-arm64) are licensed under [GPLv3](LICENSE.GPLv3). The corresponding source for that binary, including the Handbean code linked into it, is offered under GPLv3. See [LICENSE.iOS](LICENSE.iOS).
