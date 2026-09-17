# CLAUDE.md

## Primary Reference

See the root `AGENTS.md` for the main project documentation: workflow entry
points, orchestration rules, the constitution, and context management. The
component inventory lives in its "Component Inventory" section.

## Clean-room constraint

This plugin is built exclusively from public sources:
developer.hashicorp.com/vault docs, the public `hashicorp/vault/sdk` godoc,
public open-source secrets engine repos (`hashicorp/vault-plugin-secrets-openldap`,
`hashicorp/vault-plugin-secrets-terraform`, `hashicorp/vault-plugin-secrets-gcp`,
`hashi-demo-lab/vault-plugin-secrets-aap`), and for database plugins the
MPL-licensed `hashicorp/vault` builtin database backend plus public
`hashicorp/vault-plugin-database-redis`, `hashicorp/vault-plugin-database-elasticsearch`,
`hashicorp/vault-plugin-database-couchbase`, and the in-tree
`hashicorp/vault/plugins/database/*`. Do not copy content from private
skill collections or internal plugin repositories.

## Plugin packaging

The repo doubles as an installable Claude Code plugin (`.claude-plugin/`).
Run `claude plugin validate .` after changing skills, agents, or manifests.
