# E2E Case: Grafana Service Account Token Secrets Engine

**IMPORTANT** — Do not prompt me. Use the Test Defaults below for every
clarification and make best-practice decisions independently (this is an
automated eval run).

Using the **vault-secrets-e2e** skill non-interactively.

## Engine Request

Create a Vault secrets engine that manages **Grafana service-account tokens**
against the Grafana HTTP API, so applications obtain short-lived Grafana
credentials from Vault instead of long-lived tokens in config files.

### Features

- **Dynamic credentials from roles**: reading creds for a role creates a
  Grafana service account token on demand, attaches it to a Vault lease, and
  deletes the token (and its ephemeral service account, if one was created)
  on revoke. Role defines the Grafana RBAC role (Viewer/Editor/Admin) and
  token TTLs.
- **Static roles with rotation**: a static role binds to an existing Grafana
  service account; Vault rotates its token on demand (`rotate-role`) and the
  current token is readable from the static creds path.
- **Rotate-root**: rotate the root Grafana credential Vault itself uses,
  with safe write-ordering (WAL before the external mutation).
- **Hierarchical paths by organization**: Grafana service accounts are
  org-scoped, so path families nest one level under the org:
  - `config` — root credential + Grafana base URL
  - `orgs/<org>/roles/<name>` and `orgs/<org>/creds/<name>` (dynamic)
  - `orgs/<org>/static-roles/<name>` and `orgs/<org>/static-creds/<name>`
  - `rotate-root`

### Compliance

- Token values never appear in logs, error messages, or any read response
  other than the declared creds/static-creds responses
- Config storage entry is seal-wrapped
- Revocation is idempotent (a token already deleted in Grafana is success)
- Enterprise-dependent features (automated rotation schedules) must degrade
  cleanly on OSS Vault per the design template's Enterprise table

## Test Defaults

Answers to every clarify question — use these verbatim, ask nothing:

- **Credential model**: both — dynamic ephemeral tokens from roles AND
  static roles with rotation; plus rotate-root
- **Security defaults**: accept the proposed defaults — credential TTL
  default 1h / max 24h (configurable at role and mount), seal-wrap the
  `config` storage entry, root credential scoped to service-account
  administration only
- **Go module org**: `example-org` — module path
  `github.com/example-org/vault-plugin-secrets-grafana`
- **Integration environment**: **fakes only** — no live Grafana, no network
  calls in tests, no `vault server -dev` smoke mount; all tests run against
  in-memory fakes with error injection
- **Database-shape check**: not a database plugin — proceed as a logical
  secrets engine
- **Design approval**: auto-approved (harness mode)

## Workflow Instructions

- Follow best practice; use subagents per the orchestrator skills
- Don't prompt the user — make decisions yourself and record them
- If you hit issues, resolve them without prompting
