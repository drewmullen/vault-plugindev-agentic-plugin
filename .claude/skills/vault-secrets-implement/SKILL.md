---
name: vault-secrets-implement
description: SDD Phases 3-4 for Vault secrets engine development. TDD implementation and validation from an existing specs/{FEATURE}/design.md — red baseline, per-checklist-item build, full pipeline validation, PR.
user-invocable: true
argument-hint: "[feature-name] - Implement from existing specs/{feature}/design.md"
---

# SDD — Secrets Engine Implement

Builds and validates a Vault secrets engine from `specs/{FEATURE}/design.md`
using TDD in Go. Runs inside the USER'S plugin repository.

**GitHub degradation**: when the gh CLI or `origin` remote is missing, skip
issue/PR steps with a one-time warning and continue — code and reports are
still written and committed locally.

Post progress:
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/post-issue-progress.sh $ISSUE_NUMBER "<step>" "<status>" "<summary>"`.
When a phase finishes, post `complete` with the canonical phase name —
`Implement` (Phase 3), `Validate` (Phase 4) — so the script ticks the matching
box in the issue's Status checklist.

Checkpoint:
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/checkpoint-commit.sh --prefix feat "<step_name>"`
with a short hyphenated `<step_name>` (e.g., `"red-baseline"`, `"item-a-client-config"`).

## Prerequisites

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/validate-env.sh --json`. Stop
   if `gate_passed=false`. Note WARN failures (GitHub degradation mode).
2. Resolve `$FEATURE` from `$ARGUMENTS` or the current git branch name.
   Verify `specs/{FEATURE}/design.md` exists via Glob — stop if missing and
   tell the user to run `/vault-secrets-plan` first. If the design's Status
   line is not `Approved`, confirm with the user before proceeding.
3. Find `$ISSUE_NUMBER` from `$ARGUMENTS` or
   `gh issue list --search "$FEATURE"` (skip in degradation mode).

## Phase 3: Build + Test

4. Launch the `vault-secrets-test-writer` agent with the FEATURE path. It
   scaffolds the repo skeleton (go.mod, backend shell, client interface,
   entry point) and writes ALL test files from design §3/§4 scenario tables.
5. **Red baseline gate**: run `go build ./...` and `go vet ./...` — both MUST
   pass; run `go test ./...` — it MUST fail or skip (unimplemented paths),
   not error at compile. If build/vet fail, send the test-writer back once
   with the errors; stop if still failing. Checkpoint (`"red-baseline"`).
6. **Plan the dispatch** from design §6: read each item's `files:` and
   `depends-on:` declarations and group items into waves. Items may share a
   wave only when they have no `depends-on` edge between them, no file
   overlap, and no shared runtime contract (client identity, first-credential
   provisioning, backend.go path registration). YOU decide the fan-out
   within those constraints — batch related items into ONE developer
   instance when they share context (same path family, same lifecycle),
   split across concurrent instances when truly independent (typically one
   per file family). Fewer, larger dispatches cost fewer tokens (each
   instance re-loads skills + design); concurrency buys wall time only for
   independent work. State the wave plan in one line before dispatching.
7. Dispatch `vault-secrets-developer` instances per the plan (FEATURE path +
   the item text(s) in `$ARGUMENTS`). After each wave: verify `gofmt -l .`
   is empty, `go build ./...` and `go vet ./...` pass, and the wave's items
   are `[x]` in design §6. Checkpoint (`"wave-<n>-<slug>"`).
8. After all items: run `go test ./...` in full. For remaining failures,
   dispatch `vault-secrets-developer` targeted at the failing behavior — or,
   if a test itself contradicts the design, the `vault-secrets-test-writer`
   to correct it (never both for the same failure). Max 3 reconciliation
   rounds; stop and report if still red. Verify all §6 items are `[x]`.
   Checkpoint (`"implement-complete"`).
9. **In-loop review**: launch the `vault-secrets-reviewer` agent with the
   FEATURE path. It reviews the whole implementation against the known
   failure classes (bootstrap, client identity, leakage, WAL, leases,
   locking) and fixes defects directly — the point is preventing noise at
   the PR. Verify `specs/{FEATURE}/reports/review_*.md` exists via Glob and
   `go test ./...` is still green (if the reviewer broke tests, send it
   back once with the output). Checkpoint (`"review"`), post `Implement`
   complete.

## Phase 4: Validate

10. Launch the `vault-secrets-validator` agent with the FEATURE path. It runs
    the full pipeline (gofmt, vet, build, `go test -race`, golangci-lint if
    present, optional `vault server -dev` smoke mount), scores against
    `vault-judge-criteria`, applies conservative auto-fixes, and writes
    `specs/{FEATURE}/reports/validation_*.md`.
11. Verify the report exists via Glob. If the report is FAIL or scores < 8.0
    with P0/P1 issues: dispatch `vault-secrets-developer` at the specific
    remaining issues, then re-launch the validator. Max 3 rounds; if still
    failing, checkpoint and present the remaining issues to the user.
12. Checkpoint (`"validate"`), post `Validate` complete.
13. Create the PR (skip in degradation mode): push the branch, then
    `gh pr create` with a summary of paths implemented, test counts, and the
    report verdict, linking `$ISSUE_NUMBER`. Apply exactly ONE `semver:*`
    label — `semver:minor` for a new engine, `semver:patch` for fixes to an
    existing one (create the label with `gh label create` if absent).

## Done

Report: red-baseline result, wave plan + checklist items completed, review
fixes applied, final test results, validation report path + verdict, PR link
(or "local only — no remote").
