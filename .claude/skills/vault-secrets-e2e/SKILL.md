---
name: vault-secrets-e2e
description: "Non-interactive test harness for end-to-end Vault secrets engine workflow testing. Runs the full `/vault-secrets-plan` -> `/vault-secrets-implement` cycle with test defaults from a case prompt file, bypassing all user prompts for automated evaluation. Pass the case prompt file path as the skill argument."
user-invocable: true
argument-hint: "[prompt-file] - Run an E2E eval case non-interactively"
---

# E2E Test Orchestrator — Secrets Engine

Non-interactive harness mode for the eval framework in `evals/e2e/`. The
argument is the path to a **case prompt file** containing the engine request
PLUS a **Test Defaults** block that pre-answers every clarify question.

Read that file FIRST — everything below executes against its content.

## Hard rules (override the interactive workflows)

- **NO `AskUserQuestion` calls, ever.** Every answer the plan workflow would
  ask for is in the prompt file's Test Defaults block. If a question arises
  that the block does not cover, make the best-practice choice yourself and
  record it in `specs/{FEATURE}/clarifications.md`.
- **Design is auto-approved.** Where `/vault-secrets-plan` presents the
  design summary for approval, instead set the design Status line to
  `Approved`, checkpoint (`"design-approved"`), and continue straight into
  implementation.
- **GitHub degradation mode applies as documented**: this workdir has no
  `origin` remote, so skip issue/PR steps with a one-time note and keep all
  artifacts local. Do not try to add a remote.
- **Resolve problems yourself.** If a step fails, fix it and continue; never
  stop to ask.

## PART 1: PLANNING

Follow the `/vault-secrets-plan` skill phases with these differences:

- Step 2 (parse arguments): take engine name, target API, and description
  from the prompt file's Engine Request section.
- Step 6 (clarifications): copy the Test Defaults block's answers into
  `specs/{FEATURE}/clarifications.md` — mandatory slots (credential model,
  security defaults, Go module org) plus any extras it provides.
  **Integration environment defaults to "fakes only"** unless the Test
  Defaults block says otherwise — e2e eval runs never stand up live target
  containers.
- Steps 11-12 (approval): auto-approve per the hard rules above.

## PART 2: IMPLEMENTATION

Follow the `/vault-secrets-implement` skill phases unchanged (red baseline,
wave dispatch, reconciliation, in-loop review, validation). The Test Defaults
integration-environment answer is binding: tests use fakes only — never
require a live external system or a running Vault server.

## Completion

Verify before reporting:

- All checklist items in design.md §6 are `[x]`
- `specs/{FEATURE}/reports/review_*.md` and
  `specs/{FEATURE}/reports/validation_*.md` exist
- `gofmt -l .` empty; `go build ./...`, `go vet ./...`, `go test ./...` pass

Display exactly one final status line:

> E2E secrets engine test complete. Status: [PASSED|FAILED].
