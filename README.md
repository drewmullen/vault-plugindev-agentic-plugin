# vault-plugindev

Agentic workflows (Claude Code plugin) for developing HashiCorp Vault
**secrets engine** plugins in Go from a basic idea plus a target external API,
using Spec-Driven Development (4 phases: Clarify, Design, Implement, Validate).

You bring: *"I want Vault to manage credentials for `<external system>`"* and
that system's API docs. Two commands take you to a working, tested plugin repo
with a PR:

| Command                    | Purpose                                                              |
| -------------------------- | -------------------------------------------------------------------- |
| `/vault-secrets-plan`      | Phases 1-2: clarify, research, produce `design.md`, human approval gate |
| `/vault-secrets-implement` | Phases 3-4: TDD build in Go, validate, open PR                        |

Workflows run inside **your** repository: plugin code is generated at the repo
root, spec artifacts under `specs/{FEATURE}/`. A GitHub remote enables issue/PR
automation; without one the workflows warn and keep everything local.

## Status

Under active development. Milestone 1 (foundations) is complete:

- [x] **M1 Foundations** — plugin scaffold, `AGENTS.md`, core scripts, issue template, secrets constitution
- [x] **M2 Plan workflow** — clarify taxonomy, design template, research/design agents, `/vault-secrets-plan`
- [x] **M3 Implement workflow** — architecture/testing knowledge skills, test-writer/developer/validator agents, `/vault-secrets-implement`
- [ ] **M4+** — auth method workflows, database plugin workflows, e2e evals

## Layout

```
.claude-plugin/plugin.json           # Claude Code plugin manifest
.claude/
├── CLAUDE.md                        # pointer to AGENTS.md
├── agents/                          # vault-secrets-research, vault-secrets-design (+M3)
└── skills/
    ├── vault-secrets-plan/          # orchestrator + references/issue-body-template.md
    ├── vault-secrets-implement/     # orchestrator (TDD build + validate)
    ├── vault-secrets-constitution/  # non-negotiable codegen rules (knowledge)
    ├── vault-domain-category/       # clarify-phase ambiguity taxonomy (knowledge)
    ├── vault-secrets-design-template/ # design.md structure (knowledge)
    ├── vault-plugin-architecture/   # core scaffold + activity skill map (knowledge)
    ├── vault-plugin-config-client/  # config path + client seam + root rotation (activity)
    ├── vault-plugin-dynamic-roles/  # dynamic role CRUD (activity)
    ├── vault-plugin-dynamic-creds/  # creds + framework.Secret + mint WAL (activity)
    ├── vault-plugin-static-roles/   # static roles + rotation queue (activity)
    ├── vault-plugin-testing/        # test harness + fake patterns (knowledge)
    ├── vault-plugin-integration-testing/ # opt-in live test harness patterns (knowledge)
    ├── vault-judge-criteria/        # quality scoring rubric (knowledge)
    └── vault-report-template/       # Phase 4 report format (knowledge)
scripts/bash/                        # validate-env, create-new-feature,
                                     # checkpoint-commit, post-issue-progress
                                     # (run via ${CLAUDE_PLUGIN_ROOT}/scripts/bash/)
hooks/                               # PreToolUse guards (see "Guardrail hooks")
docs/                                # maintainer docs — never loaded at runtime
AGENTS.md                            # orchestration rules, component inventory
```

## Guardrail hooks

The plugin ships three PreToolUse hooks (`hooks/hooks.json`):

- **deny-out-of-tree-access.sh** — file tools stay inside the working repo;
  the installed plugin and the Go module cache are readable but read-only;
  credential files (`.vault-token`, `~/.ssh`, `~/.aws`, `*.pem`, `.env`) are
  denied everywhere. Enforces the self-containment contract: implementation
  patterns come from the skills, never from external plugin codebases.
- **deny-config-writes.sh** — no writes to harness settings, hooks, plugin
  manifests, CI workflows, or `.git/` internals.
- **deny-bash-guardrails.sh** — blocks force-push, `gh pr merge` /
  `gh repo delete`, `vault login`, machine-global config mutations
  (`git config --global`, `go env -w`), pipe-to-shell, and `rm -rf /|~`.

**Reload semantics**: hook *wiring* is snapshotted at session startup — after
installing or updating the plugin's `hooks.json`, start a new session for it
to take effect. The *scripts* are executed fresh per tool call, so script
logic changes apply immediately once wired. Note `disableAllHooks` in
settings turns these off entirely.

## E2E evals

`evals/e2e/` measures the workflows end-to-end: a case runs the full
`/vault-secrets-plan → /vault-secrets-implement` cycle headlessly in a
throwaway workdir, applies deterministic checks (design structure, checklist,
clean-room leak check, gofmt/build/vet/test), optionally grades quality with
an independent judge agent, and reports wall time / cost / results.

```bash
evals/e2e/run-eval.sh --case grafana --adapter mock         # $0 pipeline test
evals/e2e/run-eval.sh --case grafana --adapter claude-code  # metered API cost
```

See `evals/e2e/README.md` for details and the cost warning.
