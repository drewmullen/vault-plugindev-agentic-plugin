---
name: vault-db-plan
description: SDD Phases 1-2 for Vault database plugin (dbplugin.Database) development. Clarify requirements, research the target system's user-management API and the dbplugin v5 SDK patterns, produce specs/{FEATURE}/design.md, and await human approval before any code is written.
user-invocable: true
argument-hint: "[plugin-name] [target-database] - Brief description of the users/credentials the plugin should manage"
---

# SDD — Database Plugin Plan

Produces `specs/{FEATURE}/design.md` for a Vault **database plugin** — the
per-database executor behind Vault's `database/` secrets engine
(`dbplugin.Database`: Initialize / NewUser / UpdateUser / DeleteUser). Stops
for human approval before any code is written. Runs inside the USER'S plugin
repository — all artifacts land in their repo, never in this plugin.

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
2. Parse `$ARGUMENTS` for plugin name, target database/system, and
   description. Ask via `AskUserQuestion` if any is missing. **Shape
   check**: if the target has no managed-user concept and the request is
   really "mint an API token / key against a service", tell the user that
   is a logical secrets engine (`/vault-secrets-plan`), not a database
   plugin, and ask whether to stop or proceed deliberately.
3. Create GitHub issue (skip in degradation mode): read
   `${CLAUDE_PLUGIN_ROOT}/.claude/skills/vault-db-plan/references/issue-body-template.md`,
   fill the placeholders, and run
   `gh issue create --title "Database Plugin: {plugin-name}" --body "$FILLED_BODY"`.
   Capture `$ISSUE_NUMBER`. Update the issue body again after step 6 to
   include clarified decisions and scope boundaries.
4. Create feature branch:
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/create-new-feature.sh --json --workflow db --issue $ISSUE_NUMBER --short-name "<plugin-name>" "<feature description>"`
   (omit `--issue` in degradation mode). Parse the JSON output to capture
   `$BRANCH_NAME` as `$FEATURE`.
5. Scan requirements against the `vault-db-domain-category` skill — mark
   each category Clear / Partial / Missing and rank gaps by impact ×
   uncertainty.
6. Ask up to 5 clarification questions via `AskUserQuestion`. Mandatory slots:
   - **Credential features & types** — dynamic users only / + static-role
     rotation / + renewal (target has account expiry) / + root
     self-rotation; credential types (password / rsa_private_key /
     client_certificate)
   - **Statements contract** — SQL templates / JSON schema / defaults-only,
     and what empty statements do
   - **Security defaults** — TLS posture (`ca_cert`, `insecure_tls` default
     false), `verify_connection` behavior, root-account privilege scope:
     apply proposed defaults or customize
   - **Go module path** — GitHub org/user name for
     `github.com/{org}/vault-plugin-database-{name}` (skip only if already
     known from `$ARGUMENTS` or the repo's `origin` remote)
   - **Integration environment** — how should this plugin be
     integration-tested? Options: (a) public container image of the target
     database, (b) user-provided sandbox endpoint, (c) agent researches
     feasibility, (d) fakes only. For (a)/(b), also capture the
     **target tier** — which of the §2 admin operations exist in the
     runnable image (e.g. account expiry may be edition-specific); for (c)
     the research slot determines the tier; for (d) skip the tier question.
   Record answers in `specs/{FEATURE}/clarifications.md`. Checkpoint
   (`"clarify"`) and post `Clarify` complete.
7. Launch 3-5 concurrent `vault-db-research` agents as parallel foreground
   Task calls in a single message — one question each:
   - **target-admin-api**: root connection/auth model, user create / grant /
     set-password / set-expiration / delete commands or endpoints, "exists"
     and "not found" semantics, username limits, whether the root account
     can change its own password, for {target system}
   - **sdk-dbplugin-patterns**: the `dbplugin/v5` contract for this target
     shape — request/response fields actually used, `SetSupportedCredentialTypes`,
     username `template` helpers, `connutil`/`dbutil` helpers for SQL
     targets, sanitizer middleware — from public docs/godoc
   - **plugin-precedent**: config field naming, statement format, and
     method behavior precedent from comparable public open-source database
     plugins
   - **lifecycle-edge-cases**: partial NewUser failure and rollback, root
     self-rotation ordering, Vault's static-rotation retry with the same
     password, renewal on targets without expiry (include when static
     rotation, renewal, or root rotation is in scope)
   - **local-deployment**: how to run {target system} locally for
     integration tests — image+tag, bootstrap sequence, health check,
     programmatic root-account provisioning, tier feature availability
     against the §2 operations (include unless the integration-environment
     answer was "fakes only"). When the answer was "agent researches
     feasibility", this slot answers WHETHER a viable local deployment
     exists first, then how — the design agent applies the decision rule.
   Each agent receives only the FEATURE path + its question via `$ARGUMENTS`
   and writes `specs/{FEATURE}/research-{slug}.md`. Verify the files exist
   via Glob — do NOT read their contents. Re-launch any missing one once.
   **Leak gate** (mechanical — do not rely on agent compliance): run
   `grep -n -iE 'vault-plugin-(secrets|auth|database)-[a-z0-9-]+|openldap' specs/{FEATURE}/research-*.md`
   and discard hits that fall under a `### Sources` heading or that are the
   plugin's OWN module/binary name (`vault-plugin-*-{name}`). Any remaining
   hit: Edit that line to describe the pattern generically (no repo names)
   before Phase 2 — the design agent must never see precedent names outside
   Sources, and the eval leak check fails the run on them.

## Phase 2: Design

8. Launch the `vault-db-design` agent with the FEATURE path, plugin name,
   module org, and the clarified requirements summary. The agent loads the
   DB constitution and design template skills and reads
   `specs/{FEATURE}/research-*.md` itself. Output: `specs/{FEATURE}/design.md`
   with the H1 `# Database Plugin Design: …`.
9. Verify `specs/{FEATURE}/design.md` exists via Glob. Re-launch once if
   missing.
10. Grep to confirm all 7 sections are present (`## 1. Purpose` through
    `## 7. Open Questions`, with `## 2. Target System Integration` and
    `## 3. Plugin Interface Contract`) and that §4 contains an
    `Enterprise-Dependent Behavior` table. Fix inline if anything is
    missing. **Compliance gate** (mechanical): every §6 `- [ ]` item line
    must contain `files:`, `depends-on:`, and `skills:` (`grep -c` each
    against the item count); every `skills:` value must be `—` or a name
    from the template's closed list (`vault-dbplugin-connection`,
    `vault-dbplugin-users`, `vault-dbplugin-rotation`,
    `vault-dbplugin-integration-testing`); and the design must not name
    precedent plugin repos anywhere (same grep as the Phase 1 leak gate, no
    Sources exemption here; the plugin's own module/binary name stays
    exempt — never rewrite the Go Module line to dodge the grep). On failure: derive `files:`/`depends-on:` from
    the item text and ordering, and `skills:` from the item's `files:`
    (database.go/client.go → connection, users.go → users, rotation.go →
    rotation, harness → integration-testing), and Edit them in, or
    re-dispatch the design agent once with the specific gap named; rewrite
    any precedent-name line to cite its research file.
11. Checkpoint (`"research-and-design"`). Present a design summary to the
    user via `AskUserQuestion`: config fields (marking secrets), supported
    credential types, statement format, which `UpdateUser` changes are
    supported (password / expiration / public key), root self-rotation
    approach, test scenario counts (§3 + §4, noting how many are marked
    live), the integration decision (live L1+L2 vs. fakes only, plus any
    tier conflicts flagged in §7), checklist item count.
    Options: approve, review file first, request changes.
12. If changes are requested, apply them and re-present. Repeat until
    approved. On approval: checkpoint (`"design-approved"`), post `Design`
    complete.

## Done

Design approved at `specs/{FEATURE}/design.md`. Run
`/vault-db-implement $FEATURE` to build.
