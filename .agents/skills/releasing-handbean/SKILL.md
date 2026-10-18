---
name: releasing-handbean
description: Prepares and verifies a Handbean version release. Use when updating CHANGELOG.md or version.properties, cutting a release, checking release tags, or diagnosing the Pack workflow.
---

# Releasing Handbean

Prepare release metadata locally and let the repository automation own tagging and
packaging.

## Sources of truth

Read these before making release changes:

1. `version.properties` for the shared semantic version and monotonically increasing
   build number.
2. The latest entries in `CHANGELOG.md` for language and section style.
3. `scripts/version.sh` for metadata and package validation.
4. `.github/workflows/pack.yml` for current tag, build, and publication behavior.
5. Recent `chore: release Handbean ...` commits to confirm the current release diff.

Do not duplicate version values into guidance files. The root Mix project and mobile
packages consume the shared metadata through their build paths.

## Prepare a release

1. Confirm the worktree and branch. Preserve unrelated changes; a release commit should
   normally contain only `CHANGELOG.md` and `version.properties`.
2. Find the previous release commit or tag. Summarize user-visible changes since that
   boundary from Git history and the actual diffs; do not turn commit subjects into
   claims without checking the implementation.
3. Add the new changelog entry at the top. Match the established Chinese format and
   separate improvements, fixes, and version metadata only where those sections apply.
4. Update `version.properties`:
   - bump `version` according to the requested release;
   - increment `build` monotonically;
   - do not edit downstream plist, Gradle, or Mix versions by hand unless current code
     no longer reads this file.
5. Validate metadata:

   ```bash
   bash scripts/version.sh version
   bash scripts/version.sh build
   bash scripts/version.sh check-tag "v$(bash scripts/version.sh version)"
   ```

6. Run the review gates appropriate to the changes. Before calling a release ready,
   mirror `.github/workflows/pack.yml` as far as the local platform permits: warnings-as-
   errors compilation, static review, default and slow ExUnit suites, the FakeProvider
   e2e path, Web feature paths, and `npm test` when frontend code changed.
7. Review the final diff and ensure the changelog matches the shipped behavior.

## Tagging and publication

A push to `dev` that changes the version or build passes the Pack quality gate, creates
the annotated `v<version>` tag, and dispatches the tagged package build. Tagged builds
publish the release artifacts.

- Do not create or push a tag manually unless the user explicitly asks for recovery and
  the current workflow shows that automation cannot do it.
- Do not manually dispatch or accelerate a workflow without explicit approval; that
  changes shared external state.
- A local metadata edit or commit is not a published release. Report separately whether
  changes are edited, committed, pushed, tagged, packaged, and published.
- After an authorized push or pull request, follow CI and review feedback using the
  repository's GitHub event subscriptions rather than polling.

## Diagnose a failed release

Classify the failure before changing metadata:

- metadata/tag mismatch: run `scripts/version.sh` commands locally;
- quality gate failure: reproduce the named Review/Pack command;
- missing tag or release: inspect the `Tag and dispatch release` branch in `pack.yml` and
  whether the previous push changed `version.properties`;
- platform package failure: reproduce only that platform's build path and preserve the
  already valid version metadata;
- missing artifacts after successful jobs: inspect the publish job dependencies and
  artifact names before rerunning anything.

Never lower a quality gate, invent a second tag, or bump the build again merely to hide
an unexplained failure.
