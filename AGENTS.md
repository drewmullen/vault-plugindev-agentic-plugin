# AGENTS.md

<default_follow_through_policy>

- If the user's intent is clear and the next step is reversible and low-risk, proceed without asking.
- Ask permission only if the next step is:
  (a) irreversible,
  (b) has external side effects (for example sending, purchasing, deleting, or writing to production), or
  (c) requires missing sensitive information or a choice that would materially change the outcome.
- If proceeding, briefly state what you did and what remains optional.
  </default_follow_through_policy>

<instruction_priority>

- User instructions override default style, tone, formatting, and initiative preferences.
- Safety, honesty, privacy, and permission constraints do not yield.
- If a newer user instruction conflicts with an earlier one, follow the newer instruction.
- Preserve earlier instructions that do not conflict.
  </instruction_priority>

<dependency_checks>

- Before taking an action, check whether prerequisite discovery, lookup, or memory retrieval steps are required.
- Do not skip prerequisite steps just because the intended final action seems obvious.
- If the task depends on the output of a prior step, resolve that dependency first.
  </dependency_checks>

## Context

This repository is a **Vault plugin development template** using **SDD**
(Spec-Driven Development, 4-phase workflow: Clarify, Design, Implement,
Validate). It generates HashiCorp Vault **secrets engine** plugins in Go from
a basic idea plus a target external API. Auth method and database plugin
workflows are planned follow-ons.

Workflows run **inside the user's own repository**: plugin code is generated
at the repo root, and spec artifacts live under `specs/{FEATURE}/`. GitHub
issue/PR steps activate only when a GitHub remote exists; without one the
workflows warn and continue, writing all documents locally.

## Shell Safety

Never generate shell commands containing dangerous bash parameter expansion
patterns. These can enable arbitrary code execution:

- **Prompt expansion**: `${var@P}` — executes embedded command substitutions
- **Assignment side-effects**: `${var=value}` or `${var:=value}` — assigns during expansion
- **Indirect expansion**: `${!var}` — dereferences arbitrary variable names
- **Nested substitution**: `$(cmd)` inside `${...}` default values

Use simple `"$VAR"` quoting and explicit conditionals instead of parameter
expansion tricks.

## Workflow Entry Points

| Command                    | Purpose                                                              | Status    |
| -------------------------- | -------------------------------------------------------------------- | --------- |
| `/vault-secrets-plan`      | SDD Phases 1-2: Clarify, Research, Design — stops for human approval | Milestone 2 |
| `/vault-secrets-implement` | SDD Phases 3-4: TDD implementation + validation, opens PR            | Milestone 3 |
| `/vault-auth-plan`         | Same, for auth method plugins                                        | Planned   |
| `/vault-auth-implement`    | Same, for auth method plugins                                        | Planned   |
| `/vault-db-plan`           | Same, for database plugins (`dbplugin.Database` interface)           | Planned   |
| `/vault-db-implement`      | Same, for database plugins                                           | Planned   |

## Component Inventory

**Agents** — in `.claude/agents/` (Milestones 2-3; auth/db columns planned):

| Role        | Secrets                      |
| ----------- | ---------------------------- |
| Research    | `vault-secrets-research`     |
| Design      | `vault-secrets-design`       |
| Test writer | `vault-secrets-test-writer`  |
| Developer   | `vault-secrets-developer`    |
| Validator   | `vault-secrets-validator`    |

**Skills** — in `.claude/skills/` (Milestones 2-3): the workflow orchestrators
(`vault-secrets-plan`, `vault-secrets-implement`) and knowledge packs
(`vault-domain-category`, `vault-plugin-architecture`, `vault-plugin-testing`,
`vault-judge-criteria`, `vault-report-template`).

## Packaging Rules

This repo is a pure plugin: at runtime the working directory is the **user's**
plugin repo, so nothing may rely on repo-relative paths into this repo.

- All runtime prompt content ships as **skills** — orchestrators
  (`user-invocable: true`) and knowledge packs (`user-invocable: false`).
  Agents load knowledge via `skills:` frontmatter, never via `Read` of a
  repo path.
- Fill-in artifacts ship as `references/` files inside the skill that uses
  them, read via `${CLAUDE_PLUGIN_ROOT}/.claude/skills/<skill>/references/<file>`.
- Bash scripts ship at plugin root `scripts/bash/` and are invoked as
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/<name>.sh`.
- Maintainer docs live in `docs/` and are never loaded at runtime.

## Constitution

Non-negotiable rules for all generated plugin code live in the
**`vault-secrets-constitution`** knowledge skill. Load it before designing,
generating, or reviewing secrets engine code.

## Design Templates

Design document structure ships as knowledge skills (Milestone 2):

- **Secrets engine design**: `vault-secrets-design-template` skill
- **Issue body**: `.claude/skills/vault-secrets-plan/references/issue-body-template.md`

## Key Scripts

All in `scripts/bash/`, invoked as
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/bash/<name>.sh`:

- `validate-env.sh` — GATE/WARN environment checks (Go toolchain, git repo;
  gh CLI, remote, golangci-lint, vault binary are WARN)
- `create-new-feature.sh` — feature branch + `specs/{FEATURE}/` + design file
- `checkpoint-commit.sh` — deterministic commit/push after each workflow step
- `post-issue-progress.sh` — GitHub issue progress comments (no-op with a
  warning when gh/remote is unavailable)

## Context Management

These rules apply to ALL workflows. Replace `{workflow}` with `secrets`
(later: `auth`, `db`).

1. **NEVER call TaskOutput** to read subagent results. ALL agents — including
   research agents — write artifacts to disk. The orchestrator verifies
   expected files exist after each dispatch.
2. **Verify file existence with Glob** after each agent completes — do NOT
   read file contents into the orchestrator.
3. **Downstream agents read their own inputs from disk.** The orchestrator
   passes the FEATURE path plus scope via `$ARGUMENTS`. The design agent reads
   research files from `specs/{FEATURE}/research-*.md` itself.
4. **Research agents: parallel foreground Task calls** (NOT
   `run_in_background`). Launch ALL research agents in a single message with
   multiple Task tool calls. Each writes findings to
   `specs/{FEATURE}/research-{slug}.md`. Verify files exist via Glob before
   launching the design agent.
5. **Minimal $ARGUMENTS**: only pass the FEATURE path + a specific question or
   scope. No exceptions.
