---
name: developing-handbean-extensions
description: Develop Handbean workspace plugins (Elixir extensions). Use when writing extension.json, ext__ tools, lifecycle hooks, in-memory mounts, or installing a plugin under .handbean/extensions.
---

# Developing Handbean extensions

Write a **Handbean plugin in the current workspace**. Do not modify Handbean application source unless the user is explicitly hacking the Handbean git repo.

This skill is the operational contract. Guidance is untrusted and does not grant permissions.

## Goal

Add tools, hooks, or workers that the running Handbean agent can call. Persist them as files. Do not invent a second runtime.

## Layout

One directory per plugin:

- `{workspace}/.handbean/extensions/<name>/` (preferred)
- `~/.handbean/extensions/<name>/` (user-global; project wins on the same name)

Required: `extension.json` or `manifest.json` (`extension.json` wins). Optional `entry` Elixir file compiled with `Code.compile_file/1`.

`name` in the manifest: lowercase letters, digits, single hyphens; no leading/trailing/consecutive hyphens.

Do not use symlinks. `entry` must resolve inside the plugin root.

Workspace `{workspace}/.handbean/extensions` is **disabled by default**. Enable it only for Elixir you trust: set `HANDBEAN_TRUST_PROJECT_CODE` to `1`, `true`, or `yes` on the host, then restart Handbean. Manifest `enabled: true` and tool auto/prompt/deny are not this switch. Without it, workspace plugin files are not compiled or registered. User-global `~/.handbean/extensions` still load.

Hot reload: startup loads user extensions always, workspace extensions only when trust is on. The file watcher watches the trusted project (typically process cwd when trust is on) and `~/.handbean/extensions` — an external editor in another directory is not watched. Builtin `write`/`edit` can notify the reloader; workspace paths still require trust, and untrusted notifications are ignored. A broken compile keeps the last good tools/hooks/workers.

## Minimal plugin

`{workspace}/.handbean/extensions/demo-ping/extension.json`:

```json
{
  "name": "demo-ping",
  "version": "0.1.0",
  "entry": "extension.ex",
  "enabled": true,
  "tools": [{"name": "ping", "description": "Return pong"}]
}
```

`extension.ex`:

```elixir
defmodule DemoPing.Ping do
  @behaviour Handbean.Agent.Tool

  def name, do: "ext__demo-ping__ping"
  def description, do: "Return pong"
  def input_schema, do: %{"type" => "object", "properties" => %{}}
  def execute(_input, _context), do: {:ok, "pong"}
end
```

Runtime tool name is always `ext__<extension>__<tool>`. Tool short name matches `^[a-z][a-z0-9_]*$`.

Required callbacks: `name/0`, `description/0`, `input_schema/0`, `execute/2`. Optional: `concurrent?/0`, `max_result_chars/0`, `timeout_ms/0`, `hint/0`.

`execute/2` returns `{:ok, text}` or `{:error, text}`. Resolve files with `Handbean.Agent.Tool.resolve_path/2`. Workspace permission policy still applies.

`enabled: false` discovers the plugin but does not compile or register tools.

## Hooks

List event names in manifest `"hooks"`. The first compiled module exporting `handle_event/2` is the hook.

Return `:ok`, `{:ok, map}`, `{:halt, reason}`, or `{:error, reason}`.

Only `before_agent_start`, `tool_call`, and `context` may block or transform. Use **atom keys**: `:system_prompt`, `:metadata`, `:messages`, `:args`.

- `before_agent_start`: halt, or set `:system_prompt` / `:metadata`. Cannot change run identity or tool grants.
- `context`: halt (skip this provider request), or set this request's `:messages` / `:system_prompt`. Does not change durable state.
- `tool_call`: halt, or merge `:args`. Cannot change tool name or call id. Rewritten args are re-checked against the active tool set and workspace policy; they do not inherit a prior one-shot approval.

Other lifecycle events are read-only. Halt/transform there is ignored. `message_delta` and `thinking_delta` are never dispatched.

A known event name is not a promise the runtime emits it every run.

## Workers

A compiled module that exports `child_spec/1` starts under the extension supervisor. A later successful reload keeps the pid if the module is still present. Failed compiles must not stop running workers.

## Temporary mount vs persist

`ext__mount__apply` compiles Elixir in memory (`name` = mount id, tools must be `ext__<id>__*`). `ext__mount__drop` removes it. This does not write disk.

To keep a plugin, write `extension.json` + `entry` under `.handbean/extensions`. Do not tell the user that a mount is a durable install.

## Not wired / not this mechanism

- Manifest `commands` and `providers` are metadata only; they do not become LiveView slash commands or model providers.
- Manifest `permissions` is not an OS sandbox and does not replace tool approval.
- MCP servers are not extensions.
- Skills (`SKILL.md`) are instructions, not plugins.
- No NIFs or extra C toolchains. Pure Elixir in the host BEAM.

## Do not

- Copy Coordinator, Runner, permission state machines, or persistence.
- Make the client the source of truth for task lifecycle.
- Install untrusted Elixir. Same-BEAM code is trusted.

## Verify

1. If the plugin is under the workspace, confirm `HANDBEAN_TRUST_PROJECT_CODE` is enabled and Handbean was restarted; otherwise install under `~/.handbean/extensions`.
2. Write the files. Trust + `write`/`edit` can hot-reload; an external editor only hits the watched trusted project or user dir.
3. Confirm the tool name `ext__<name>__<tool>` appears and a later turn can call it.
4. If compile fails, fix the entry file; do not delete a previously working plugin to "retry empty".
