---
name: verifying-handbean-mobile
description: Selects and executes Handbean Android and iOS validation at host, package, simulator, or physical-device level. Use for changes under mobile/, mobile host capabilities, static NIFs, packaging, or claims about native behavior.
---

# Verifying Handbean Mobile

Choose the lowest validation layer that can catch the regression, then clearly report
what higher layers were not run. Never promote host tests or simulator results to a
physical-device conclusion.

## Read first

1. `mobile/AGENTS.md` for current product and host invariants.
2. `docs/mobile-device-verification.md` for the full acceptance matrix and evidence
   rules.
3. The pinned tooling documentation in `mobile/deps/mob_dev/README.md` and `mix help`
   under `mobile/`; do not assume current upstream `master` matches the pin.
4. The relevant platform workflow, pack script, and changed host code.

## Pick the validation layer

### 1. Host-only Elixir

Use for pure Elixir state, payload normalization, rendering trees, and code that does
not require a platform bridge:

```bash
cd mobile
mix deps.get
mix test path/to/affected_test.exs
mix test
```

These tests must not load Android/iOS NIFs. A `Mob.ScreenCase` result is host-side, not
device acceptance.

### 2. Root/mobile contract

Changes to Coordinator, Runner, transcript, projections, tools, settings, or shared
schemas can affect both clients. Run the relevant root tests as well as mobile tests.
Use FakeProvider or another controlled provider; do not spend model credits merely to
exercise transport.

### 3. Package or simulator

Required for static NIF lists, Kotlin/Swift bridges, manifests, native assets, package
metadata, ABI changes, or cold-start behavior. Use the checked-in scripts and exact
toolchain pins. Repack after hot-loading; temporary RPC code is not evidence that the
installed artifact contains the fix.

Record the artifact path/hash, ABI, OS/runtime, exact commit, dirty state, commands, and
decisive output. Label emulator/ARC results as such.

### 4. Physical device

Required before claiming Android or iOS device acceptance. Follow
`docs/mobile-device-verification.md`; report Android and iOS independently as
`PASS`, `FAIL`, `BLOCKED`, `NOT_RUN`, or `N/A`.

Installing over an app, force-stopping it, clearing data, using credentials, making paid
model calls, or operating a shared device may require user authorization. Inspect data
risk first. Never uninstall or clear real user data to make a test pass.

## Evidence order

1. Prove handler/runtime behavior through `Mob.Test`, bounded RPC, Runner/Session state,
   transcript APIs, or output files. Do not dump credentials or complete assigns.
2. For visual changes, capture and inspect the actual native screen in every affected
   state. A screenshot proves appearance, not persistence or handler success.
3. For persistence/NIF changes, perform a true cold start from the newly packed artifact
   and verify read/write behavior, not only module loading or build exit status.
4. For cross-client changes, check the same durable transcript/projection contract on
   root and mobile paths; do not implement a mobile-only shadow contract.

## Safety and ownership

- One agent drives a device at a time. Read-only inspection by others is acceptable.
- Select the device explicitly; do not operate the first `adb devices` entry by default.
- Do not expose distributed Erlang publicly, disable authentication, loosen
  `PathValidator`, or enable shell capabilities on phones for easier testing.
- Do not use `adb screencap` or UI automation to infer internal handler state when the
  Mob node can be queried.
- Preserve unrelated tunnels and device sessions; never use broad cleanup commands such
  as `adb forward --remove-all`.

## Report

State the exact layer reached and separate these facts:

- host tests passed;
- package built and was inspected;
- simulator/ARC cold-started;
- Android physical device passed;
- iOS physical device passed.

List blocked and unrun layers explicitly. A successful pack, install, foreground
process, screenshot, or RPC hot-load alone is not a native feature acceptance result.
