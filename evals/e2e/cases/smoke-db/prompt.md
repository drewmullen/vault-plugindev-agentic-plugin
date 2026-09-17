# E2E Case: Acme KV Database Plugin (smoke)

**IMPORTANT** — Do not prompt me. Use the Test Defaults below for every
clarification and make best-practice decisions independently (this is an
automated eval run).

Using the **vault-db-e2e** skill non-interactively.

This is the SMOKE case: a deliberately small database plugin against a
fictional key-value store whose complete admin API is embedded below. Do not
research the target system on the web — the spec below is authoritative and
complete. (Vault SDK research proceeds as normal.)

## Plugin Request

Create a Vault **database plugin** (`dbplugin.Database`) for **Acme KV**, a
fictional key-value store with an HTTP admin API, so applications obtain
short-lived Acme KV users from Vault's `database/` secrets engine instead
of sharing long-lived accounts.

### Features

- **Dynamic users**: `NewUser` creates an Acme KV user with the
  Vault-supplied password and the roles named in the creation statements;
  `DeleteUser` removes it (idempotent when already gone).
- **Password rotation**: `UpdateUser` changes a user's password
  (static-role rotation) and handles **root self-rotation** — when the
  username equals the configured root user, the plugin adopts the new
  password in memory and keeps working through Vault's Close +
  re-Initialize.
- **Expiration**: Acme KV supports `expires_at` on users; apply
  `NewUser.Expiration` at create time and support `UpdateUser.Expiration`
  (renewal).
- **Credential types**: password only. Reject others before any target call.

### Target Admin API Specification (authoritative — do not research online)

Base URL from `connection_url`; auth via HTTP basic (`username`/`password`
from config). Usernames: max 32 chars, lowercase `[a-z0-9-]`.

| Operation | Endpoint | Request | Response / Errors |
|---|---|---|---|
| Ping | `GET /admin/ping` | — | 200 `{"ok":true}`; 401 bad credentials |
| Create user | `PUT /admin/users/{name}` | `{"password":"…","roles":["reader"],"expires_at":<unix>}` (`expires_at` optional) | 201 created; 409 exists; 422 unknown role |
| Set password | `POST /admin/users/{name}/password` | `{"password":"…"}` | 204; 404 unknown user |
| Set expiration | `POST /admin/users/{name}/expiration` | `{"expires_at":<unix>}` | 204; 404 unknown user |
| Delete user | `DELETE /admin/users/{name}` | — | 204; **404 treated as success** |

- Creation statements: JSON `{"roles":["reader"|"writer"|"admin"]}`; empty
  statements → default role `reader`.
- Revocation/rotation/renew statements: not used (defaults apply); if
  supplied, ignore them and document it.
- Errors are JSON `{"error":"message"}`. Rate limits: none.

### Compliance

- The configured password never appears in errors (sanitizer middleware
  with `secretValues()`), logs, or any response
- `InitializeResponse.Config` echoes the request config; supported
  credential types declared as password only
- `DeleteUser` is idempotent per the API spec above
- No Vault paths, storage, leases, or WAL in the plugin — Vault core owns them

## Test Defaults

Answers to every clarify question — use these verbatim, ask nothing:

- **Credential features & types**: dynamic users + static-role password
  rotation + renewal (expiration) + root self-rotation; password credentials
  only
- **Statements contract**: JSON `{"roles":[…]}` for creation statements,
  default role `reader` when empty; other statement sets ignored (documented)
- **Security defaults**: accept the proposed defaults — HTTPS via
  `connection_url`, optional `ca_cert`, `insecure_tls` default false,
  `verify_connection` performs the ping; root account needs user
  create/update/delete only
- **Go module org**: `example-org` — module path
  `github.com/example-org/vault-plugin-database-acmekv`
- **Integration environment**: **fakes only** — no live target, no network
  calls in tests; all tests run against an in-memory fake client with error
  injection
- **Shape check**: this is a database plugin — proceed with `/vault-db-plan`
- **Design approval**: auto-approved (harness mode)

## Workflow Instructions

- Follow best practice; use subagents per the orchestrator skills
- Keep the design §6 checklist small (3 items: connection, users, rotation)
- Don't prompt the user — make decisions yourself and record them
- If you hit issues, resolve them without prompting
