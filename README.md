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
- [ ] **M3 Implement workflow** — architecture/testing knowledge skills, test-writer/developer/validator agents, `/vault-secrets-implement`
- [ ] **M4+** — auth method workflows, database plugin workflows, e2e evals

## Layout

```
.claude-plugin/plugin.json           # Claude Code plugin manifest
.claude/
├── CLAUDE.md                        # pointer to AGENTS.md
├── agents/                          # vault-secrets-research, vault-secrets-design (+M3)
└── skills/
    ├── vault-secrets-plan/          # orchestrator + references/issue-body-template.md
    ├── vault-secrets-constitution/  # non-negotiable codegen rules (knowledge)
    ├── vault-domain-category/       # clarify-phase ambiguity taxonomy (knowledge)
    └── vault-secrets-design-template/ # design.md structure (knowledge)
scripts/bash/                        # validate-env, create-new-feature,
                                     # checkpoint-commit, post-issue-progress
                                     # (run via ${CLAUDE_PLUGIN_ROOT}/scripts/bash/)
docs/                                # maintainer docs — never loaded at runtime
AGENTS.md                            # orchestration rules, component inventory
```

## Clean-room constraint

Built exclusively from public HashiCorp sources: developer.hashicorp.com/vault,
the public `hashicorp/vault/sdk` godoc, and public open-source plugin repos
(`vault-plugin-secrets-openldap`, `vault-plugin-secrets-terraform`). No content
from private skill collections or internal plugin repositories.
