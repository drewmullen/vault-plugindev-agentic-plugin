# E2E Case: Acme Deploy Token Secrets Engine (smoke)

**IMPORTANT** — Do not prompt me. Use the Test Defaults below for every
clarification and make best-practice decisions independently (this is an
automated eval run).

Using the **vault-secrets-e2e** skill non-interactively.

This is the SMOKE case: a deliberately small engine against a fictional API
whose complete specification is embedded below. Do not research the target
API on the web — the spec below is authoritative and complete. (Vault SDK
research proceeds as normal.)

## Engine Request

Create a Vault secrets engine that manages **Acme deploy tokens** against
the Acme Deploy HTTP API, so CI jobs obtain short-lived deploy tokens from
Vault instead of long-lived tokens in pipeline config.

### Features

- **Dynamic credentials from roles**: reading creds for a role creates an
  Acme deploy token on demand, attaches it to a Vault lease, and deletes the
  token on revoke. A role defines the Acme project and the token scope
  (`read` or `deploy`) plus TTLs.
- **Rotate-root**: rotate the root Acme API token Vault itself uses, with
  safe write-ordering (WAL before the external mutation).
- **Flat paths**: `config`, `roles/<name>`, `creds/<name>`, `rotate-root`.
  No hierarchy, no static roles.

### Target API Specification (authoritative — do not research online)

Base URL configurable; auth via `Authorization: Bearer <token>` header.

| Operation | Endpoint | Request | Response / Errors |
|---|---|---|---|
| Verify token | `GET /v1/self` | — | 200 `{"id":"tok_...","project":"*"}`; 401 invalid token |
| Create token | `POST /v1/projects/{project}/tokens` | `{"scope":"read"\|"deploy","ttl_seconds":int}` | 201 `{"id":"tok_...","secret":"acme_...","expires_at":ts}` — `secret` returned ONCE; 404 unknown project; 422 invalid scope |
| Delete token | `DELETE /v1/tokens/{id}` | — | 204 deleted; **404 treated as success** (idempotent revoke) |
| Rotate root | `POST /v1/self/rotate` | — | 201 `{"id":"tok_...","secret":"acme_..."}` — old token remains valid for 60s grace, then dies |

- Rate limits: none documented. Errors are JSON `{"error":"message"}`.
- Tokens are project-scoped; the root token is all-projects (`"project":"*"`).

### Compliance

- Token secrets never appear in logs, error messages, or any read response
  other than the declared `creds/<name>` response
- Config storage entry is seal-wrapped
- Revocation is idempotent per the API spec above
- Enterprise-dependent features (automated rotation schedules) must degrade
  cleanly on OSS Vault per the design template's Enterprise table

## Test Defaults

Answers to every clarify question — use these verbatim, ask nothing:

- **Credential model**: dynamic ephemeral tokens only, plus rotate-root. No
  static roles.
- **Security defaults**: accept the proposed defaults — credential TTL
  default 1h / max 24h (configurable at role and mount), seal-wrap the
  `config` storage entry
- **Go module org**: `example-org` — module path
  `github.com/example-org/vault-plugin-secrets-acme`
- **Integration environment**: **fakes only** — no live target, no network
  calls in tests; all tests run against in-memory fakes with error injection
- **Database-shape check**: not a database plugin — proceed as a logical
  secrets engine
- **Design approval**: auto-approved (harness mode)

## Workflow Instructions

- Follow best practice; use subagents per the orchestrator skills
- Keep the design §6 checklist small (3-4 items) — this is a minimal engine
- Don't prompt the user — make decisions yourself and record them
- If you hit issues, resolve them without prompting
