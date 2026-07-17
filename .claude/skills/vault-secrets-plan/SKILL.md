---
name: vault-secrets-plan
description: SDD Phases 1-2 for Vault secrets engine development. Clarify requirements, research the target API and Vault SDK patterns, produce specs/{FEATURE}/design.md, and await human approval before any code is written.
user-invocable: true
argument-hint: "[engine-name] [target-api] - Brief description of what credentials the engine should manage"
---

# SDD — Secrets Engine Plan

Produces `specs/{FEATURE}/design.md` from requirements. Stops for human
approval before any code is written. Runs inside the USER'S plugin repository
— all artifacts land in their repo, never in this plugin.

**GitHub degradation**: issue/PR automation requires the gh CLI and an
`origin` remote. When either is missing (WARN checks in step 1), tell the user
once that no issue will be created, skip steps that need GitHub, and continue
— all spec documents are still written and committed locally.

Post progress at key steps:
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/post-issue-progress.sh $ISSUE_NUMBER "<step>" "<status>" "<summary>"`.
Valid status values: `started`, `in-progress`, `complete`, `failed`. When a
phase finishes, post `complete` with the canonical phase name — `Clarify`
(Phase 1), `Design` (Phase 2) — so the script ticks the matching box in the
issue's Status checklist. (The script itself no-ops with a warning when
GitHub is unavailable.)

Checkpoint after each phase:
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/checkpoint-commit.sh "<step_name>"`.
The `<step_name>` must be a short hyphenated identifier (e.g., `"clarify"`,
`"research-and-design"`, `"design-approved"`) — NOT a sentence or file path.

## Phase 1: Requirements & Research

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/validate-env.sh --json`. Stop
   if `gate_passed=false` and show the failed GATE checks. Note which WARN
   checks failed: `GH_REMOTE`/`GH_CLI` failures switch this run to GitHub
   degradation mode.
2. Parse `$ARGUMENTS` for engine name, target API/system, and description.
   Ask via `AskUserQuestion` if any is missing. **Database-shape check**: if
   the request is "manage users/credentials in a database" (Postgres, MySQL,
   MongoDB, etc. via SQL/driver), tell the user that database plugins use the
   `dbplugin.Database` interface, which this workflow does not generate (a
   dedicated workflow is planned), and ask whether to stop or proceed with a
   logical secrets engine deliberately.
3. Create GitHub issue (skip in degradation mode): read
   `${CLAUDE_PLUGIN_ROOT}/.claude/skills/vault-secrets-plan/references/issue-body-template.md`,
   fill the placeholders, and run
   `gh issue create --title "Secrets Engine: {engine-name}" --body "$FILLED_BODY"`.
   Capture `$ISSUE_NUMBER`. Update the issue body again after step 6 to
   include clarified decisions and scope boundaries.
4. Create feature branch:
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/create-new-feature.sh --json --workflow secrets --issue $ISSUE_NUMBER --short-name "<engine-name>" "<feature description>"`
   (omit `--issue` in degradation mode). Parse the JSON output to capture
   `$BRANCH_NAME` as `$FEATURE`.
5. Scan requirements against the `vault-domain-category` skill — mark each
   category Clear / Partial / Missing and rank gaps by impact × uncertainty.
6. Ask up to 5 clarification questions via `AskUserQuestion`. Mandatory slots:
   - **Credential model** — static rotation vs. dynamic ephemeral vs. both
   - **Security defaults** — default/max TTLs, seal-wrap candidates,
     root-credential scope: apply proposed defaults or customize
   - **Go module path** — GitHub org/user name for
     `github.com/{org}/vault-plugin-secrets-{name}` (skip only if already
     known from `$ARGUMENTS` or the repo's `origin` remote)
   - **Integration environment** — how should this engine be
     integration-tested? Options: (a) public container image of the target
     system, (b) user-provided sandbox endpoint, (c) agent researches
     feasibility, (d) fakes only. For (a)/(b), also capture the
     **target-system tier** — which of the §2 endpoints exist in the runnable
     image/sandbox (e.g. some features are Enterprise-only); for (c) the
     research slot determines the tier; for (d) skip the tier question.
   Record answers in `specs/{FEATURE}/clarifications.md`. Checkpoint
   (`"clarify"`) and post `Clarify` complete.
7. Launch 3-5 concurrent `vault-secrets-research` agents as parallel
   foreground Task calls in a single message — one question each:
   - **target-api**: auth model, credential-management endpoints, error
     semantics, rate limits for {target system}
   - **sdk-patterns**: `framework.Backend` patterns for this engine shape
     (paths, storage, leases, WAL, rotation) from public docs/godoc
   - **plugin-precedent**: layout precedent from comparable public
     open-source plugins
   - **lifecycle-edge-cases**: revocation races, rotation failure recovery,
     idempotency (include when the credential model involves rotation or
     dynamic credentials)
   - **local-deployment**: how to run {target system} locally for integration
     tests — image+tag, bootstrap sequence, health check, programmatic token
     provisioning, tier feature availability against the §2 endpoint needs
     (include unless the integration-environment answer was "fakes only").
     When the answer was "agent researches feasibility", this slot answers
     WHETHER a viable local deployment exists first, then how — the design
     agent applies the decision rule to its findings. Phase 1 order is
     unchanged: feasibility lands in this existing research step.
   Each agent receives only the FEATURE path + its question via `$ARGUMENTS`
   and writes `specs/{FEATURE}/research-{slug}.md`. Verify the files exist
   via Glob — do NOT read their contents. Re-launch any missing one once.
   **Leak gate** (mechanical — do not rely on agent compliance): run
   `grep -n -iE 'vault-plugin-(secrets|auth|database)-[a-z-]+|openldap' specs/{FEATURE}/research-*.md`
   and discard hits that fall under a `### Sources` heading. Any remaining
   hit: Edit that line to describe the pattern generically (no repo names)
   before Phase 2 — the design agent must never see precedent names outside
   Sources, and the eval leak check fails the run on them.

## Phase 2: Design

8. Launch the `vault-secrets-design` agent with the FEATURE path, engine
   name, module org, and the clarified requirements summary. The agent loads
   the constitution and design template skills and reads
   `specs/{FEATURE}/research-*.md` itself. Output: `specs/{FEATURE}/design.md`.
9. Verify `specs/{FEATURE}/design.md` exists via Glob. Re-launch once if
   missing.
10. Grep to confirm all 7 sections are present (`## 1. Purpose` through
    `## 7. Open Questions`) and that §4 contains an
    `Enterprise-Dependent Features` table. Fix inline if anything is missing.
    **Compliance gate** (mechanical): every §6 `- [ ]` item line must contain
    `files:`, `depends-on:`, and `skills:` (`grep -c` each against the item
    count); every `skills:` value must be `—` or a name from the template's
    closed list (`vault-plugin-config-client`, `vault-plugin-dynamic-roles`,
    `vault-plugin-dynamic-creds`, `vault-plugin-static-roles`,
    `vault-plugin-integration-testing`); and the design must not name
    precedent plugin repos anywhere (same grep as the Phase 1 leak gate, no
    Sources exemption here). On failure: derive `files:`/`depends-on:` from
    the item text and ordering, and `skills:` from the item's `files:`
    (path_config/client → config-client, path_roles → dynamic-roles,
    creds/secret_ → dynamic-creds, static → static-roles, harness →
    integration-testing), and Edit them in, or re-dispatch the design agent
    once with the specific gap named; rewrite any precedent-name line to
    cite its research file.
11. Checkpoint (`"research-and-design"`). Present a design summary to the
    user via `AskUserQuestion`: path families and topology (flat vs.
    hierarchical), storage entries and seal-wrap list, credential
    model/lifecycle, test scenario counts (§3 + §4, noting how many are
    marked live), the integration decision (live L1+L2 vs. fakes only, plus
    any tier conflicts flagged in §7), checklist item count.
    Options: approve, review file first, request changes.
12. If changes are requested, apply them and re-present. Repeat until
    approved. On approval: checkpoint (`"design-approved"`), post `Design`
    complete.

## Done

Design approved at `specs/{FEATURE}/design.md`. Run
`/vault-secrets-implement $FEATURE` to build.
