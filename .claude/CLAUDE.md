# CLAUDE.md

## Primary Reference

See the root `AGENTS.md` for the main project documentation: workflow entry
points, orchestration rules, the constitution, and context management. The
component inventory lives in its "Component Inventory" section.

## Clean-room constraint

This plugin is built exclusively from public HashiCorp sources:
developer.hashicorp.com/vault docs, the public `hashicorp/vault/sdk` godoc,
and public open-source plugin repos (`vault-plugin-secrets-openldap`,
`vault-plugin-secrets-terraform`). Do not copy content from private skill
collections or internal plugin repositories.

## Plugin packaging

The repo doubles as an installable Claude Code plugin (`.claude-plugin/`).
Run `claude plugin validate .` after changing skills, agents, or manifests.
