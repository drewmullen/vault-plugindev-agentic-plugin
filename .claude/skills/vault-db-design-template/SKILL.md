---
name: vault-db-design-template
description: Canonical 7-section structure for a Vault database plugin design.md — purpose, target system integration, plugin interface contract (config fields, statements, credential types, method contracts), credential lifecycle with Vault-core Enterprise notes, security controls, implementation checklist, open questions. Load when authoring or reviewing a database plugin's specs/{FEATURE}/design.md.
user-invocable: false
---

# Vault Database Plugin Design Template

The design agent writes `specs/{FEATURE}/design.md` following this structure
exactly. `{braces}` mark fill-ins; brace-wrapped paragraphs are guidance to
the author and are NOT copied into the document. Template rules are at the end.

The seven `## N.` headers are load-bearing: hooks and eval checks grep them.
The H1 prefix `# Database Plugin Design:` is how tooling tells this document
apart from a secrets-engine design.

---

# Database Plugin Design: {plugin-name}

**Branch**: {NNN-short-name}
**Date**: {YYYY-MM-DD}
**Status**: Draft | Approved | Implementing | Complete
**Target System**: {database/system + version}
**Go Module**: github.com/{org}/vault-plugin-database-{name}
**Plugin Type**: `{name}` — {the string `Type()` returns}
**Go Version**: >= {version}

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Target System Integration](#2-target-system-integration)
3. [Plugin Interface Contract](#3-plugin-interface-contract)
4. [Credential Lifecycle](#4-credential-lifecycle)
5. [Security Controls](#5-security-controls)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

{One paragraph. Which database/system this plugin manages users in, who
consumes the credentials through Vault's `database/` engine, and what problem
it solves. Remember: Vault core owns the HTTP paths, leases, and scheduling —
this plugin executes user operations.}

**Credential features**: {dynamic users (NewUser/DeleteUser) | + static-role
rotation (UpdateUser password) | + renewal (UpdateUser expiration) | + root
self-rotation} — {one-line rationale}

**Credential types**: {password | password + rsa_private_key | password +
client_certificate} — {what the target can authenticate with}

**Scope boundary**: {What is explicitly OUT of scope — e.g. no expiration
support because the target has no account expiry; no client-certificate
credentials.}

### Requirements

**Functional requirements** — from Phase 1 clarification:

- {Testable statement of required capability}
- ...

**Non-functional requirements**:

- {Constraint or quality attribute that bounds the design}
- ...

---

## 2. Target System Integration

{This section makes "bring your own database" work — filled from research files.}

### Authentication

- **Root connection model**: {username/password over TLS | bearer token | mTLS | …}
- **Root account provisioning**: {how the operator creates and scopes the
  account Vault's `config/<name>` uses}

### Admin Operations Used

| Lifecycle operation | Target command / API call | Request essentials | Success / error semantics |
|--------------------|---------------------------|--------------------|---------------------------|
| {verify connection} | {SELECT 1 / GET /ping} | {…} | {ok; auth failure} |
| {create user} | {CREATE USER … / PUT /users/{name}} | {…} | {created; exists → ?} |
| {grant roles} | {GRANT … / roles[] in body} | {…} | {…} |
| {set password} | {ALTER USER … PASSWORD / POST /users/{name}/password} | {…} | {…} |
| {set expiration} | {ALTER USER … VALID UNTIL / expires_at} | {…} | {unsupported → say so} |
| {delete user} | {DROP USER … / DELETE /users/{name}} | {…} | {gone; not-found treated as success} |
| ... | | | |

### Client Choice

**{`database/sql` + driver X via connutil.SQLConnectionProducer | official Go SDK vX | plain net/http}**.
*Rationale*: {why, citing research}.
*Rejected*: {alternative and why not}.

### Rate Limits & Error Semantics

- {Documented limits; retry/backoff; which failures are operator errors
  (bad config) vs. target failures}
- {Idempotency per operation — critical for delete and password change}

### Integration Test Environment

{From the Phase 1 integration-environment clarification and the
`local-deployment` research file. When the clarify answer was "agent
researches feasibility", the Decision below comes from that research's
feasibility verdict. Stays under §2 — do NOT add a new top-level section.}

- **Runnable target**: {image + exact tag (never `:latest`) | user-provided
  sandbox endpoint | none}
- **Tier**: {edition, and an explicit list of §2 operations UNAVAILABLE in it}
- **Bootstrap**: {one-line sequence — compose up → wait healthy → create
  root account / obtain admin token → write integration.env}
- **Decision**: {live L1+L2 | fakes only} — {rationale}

---

## 3. Plugin Interface Contract

### Architectural Decisions

**{Decision title}**: {What was chosen}.
*Rationale*: {Why, citing research findings and/or skill sections. Never
direct implementers to external repos or codebases.}
*Rejected*: {What was considered and why rejected}.

{Must include: the connection-producer decision (wrap
`connutil.SQLConnectionProducer` vs. a custom client behind the seam), the
statement-format decision (SQL templates vs. JSON schema vs. none/defaults),
and the username-template default.}

### Config Fields (`database/config/<name>` pass-through)

{Fields the operator supplies that Vault forwards to `Initialize`. Vault
strips its own fields first (plugin_name, allowed_roles, verify_connection,
password_policy, root_rotation_statements, rotation scheduling) — never list
those here.}

| Field | Type | Required | Default | Secret | Description |
|-------|------|:-:|---------|:-:|-------------|
| `connection_url` | string | yes | — | {yes if it may embed creds} | {…} |
| `username` | string | yes | — | no | root account |
| `password` | string | yes | — | **yes** | root password — redacted via secretValues |
| `username_template` | string | no | `{default}` | no | Go template; see Username Generation |
| `{ca_cert}` | string | no | — | no | {…} |
| `{insecure_tls}` | bool | no | false | no | {…} |
| ... | | | | | |

### Supported Credential Types

| CredentialType | Supported | How applied |
|----------------|:-:|-------------|
| `password` | yes | {statement/command that sets it} |
| `rsa_private_key` | {yes/no} | {public key installed via …} |
| `client_certificate` | {yes/no} | {subject mapped via …} |

### Statements Contract

| Statement set | Delivered in | Format | Template variables | When empty |
|---------------|--------------|--------|--------------------|------------|
| `creation_statements` | `NewUserRequest.Statements` | {SQL list / JSON `{"roles":[…]}`} | {`{{name}}`, `{{username}}`, `{{password}}`, `{{expiration}}`} | {default or `ErrEmptyCreationStatement`} |
| `rollback_statements` | `NewUserRequest.RollbackStatements` | {…} | {…} | {best-effort delete} |
| `revocation_statements` | `DeleteUserRequest.Statements` | {…} | {…} | {default delete} |
| `rotation_statements` | `UpdateUserRequest.Password.Statements` | {…} | {…} | {default password change} |
| `renew_statements` | `UpdateUserRequest.Expiration.Statements` | {…} | {…} | {default / unsupported} |

### Username Generation

- **Default template**: `{e.g. {{ printf "v-%s-%s-%s-%s" (.DisplayName | truncate 8) (.RoleName | truncate 8) (random 20) (unix_time) | truncate 63 }}`}
- **Target limits**: {max length, allowed charset, case rules — and how the
  plugin enforces them after rendering}

### Method Contract

| Method | Inputs used | Target effect | Returns | Errors (message intent) | Never returns / logs |
|--------|-------------|---------------|---------|-------------------------|----------------------|
| `Initialize` | Config, VerifyConnection | {ping when verify} | Config echoed + supported types | {field missing; ping failed} | password, keys |
| `NewUser` | UsernameConfig, Statements, RollbackStatements, CredentialType, Password/PublicKey, Expiration | {create + grant [+ expiry]} | Username | {parse; unsupported type; create failed (rolled back)} | password, statements |
| `UpdateUser` | Username, Password/Expiration/PublicKey, SelfManagedPassword | {set password / expiry / key} | — | {unknown user; unsupported change} | new password |
| `DeleteUser` | Username, Statements | {drop user} | — | {target failure other than not-found} | statements |
| `Type` | — | — | `"{name}"` | — | — |
| `Close` | — | {release client} | — | — | — |

### Method Test Scenarios

{Table-driven scenarios the test-writer converts into `*_test.go`. Every
method needs at least: happy path, validation rejection, and
never-returns-secrets where applicable. The `live?` column marks scenarios
that ALSO run as env-gated acceptance tests against the real target (only
when §2's decision is live; all "no" when fakes-only).}

| Scenario | Method | Purpose | Test function | live? |
|----------|--------|---------|---------------|:---:|
| {Valid config decodes, echoes config, declares password type} | `Initialize` | … | `TestInitialize_{…}` | {yes/no} |
| {Missing `username` rejected naming the field} | `Initialize` | validation | `TestInitialize_{…}` | no |
| {verify_connection=true pings; ping failure fails init} | `Initialize` | … | `TestInitialize_{…}` | {yes/no} |
| {Bad username_template rejected at config time} | `Initialize` | … | `TestInitialize_{…}` | no |
| {Statement parse error rejected before any target call} | `NewUser` | … | `TestNewUser_{…}` | no |
| {Delete of absent user succeeds} | `DeleteUser` | idempotency | `TestDeleteUser_{…}` | {yes/no} |
| {Method before Initialize errors} | all | … | `TestNotInitialized` | no |
| ... | | | | |

---

## 4. Credential Lifecycle

### Model

{Narrative of the division of labor: Vault core generates the password,
computes expiration from the lease (+5s buffer), sanitizes DisplayName,
calls NewUser; attaches the lease; on revoke calls DeleteUser; on renew calls
UpdateUser(Expiration) only when `renew_statements` are set; on static-role
rotation calls UpdateUser(Password) with `rotation_statements`; on
rotate-root calls UpdateUser(Password) with `root_rotation_statements` and
Username = config username, then persists the new password, Closes, and
re-Initializes. State what THIS plugin does at each of those calls.}

### Expiration

- **NewUser.Expiration**: {applied via … | not applied — target has no
  account expiry; lease is the only expiry}
- **UpdateUser.Expiration** (renewal): {applied via … | returns error
  "expiration not supported" — operators must not set renew_statements}

### Root Self-Rotation

- **Detection**: `req.Username == config.username`
- **Ordering**: target accepts new password → in-memory config updated → raw
  config map `password` key updated → client rebuilt/re-authenticated
- **Failure at each step**: {target rejects → nothing changes, error
  returned; target accepts but client rebuild fails → error returned, Vault
  still persists new password and re-Initializes on next use — plugin must
  not be wedged}

### Static-Role Rotation

- **UpdateUser.Password path**: {statements used or default; retry behavior
  when Vault re-sends the same password after a transient failure —
  idempotent}
- **SelfManagedPassword**: {honored: authenticate as the user to change its
  own password | ignored: rotation always via root — documented in README}

### Enterprise-Dependent Behavior

{One row per Vault-core Enterprise feature that produces plugin calls. The
plugin cannot detect the feature; the row records what it does either way.}

| Feature (Vault core) | Plugin sees | Plugin behavior when feature is off |
|----------------------|-------------|-------------------------------------|
| Automated root rotation | `UpdateUser(Password)` with Username = root | Never called; manual `rotate-root` produces the identical call |
| Static-role scheduled rotation | `UpdateUser(Password)` | Never called; manual `rotate-role` produces the identical call |
| `skip_import_rotation` | First `UpdateUser` deferred | No plugin difference |
| `self_managed_password` | `SelfManagedPassword` set | Field empty; plugin uses root path |

### Lifecycle Test Scenarios

{Scenarios the test-writer converts into lifecycle tests. Must cover:
create, delete (+idempotent), password change, root self-rotation,
expiration (applied or documented error), create-failure rollback, and the
sanitizer. Same `live?` rules as §3.}

| Scenario | Transition | Purpose | Test function | live? |
|----------|-----------|---------|---------------|:---:|
| {NewUser creates user with template username, password, roles} | create | … | `TestNewUser_{…}` | {yes/no} |
| {NewUser target failure after create triggers rollback delete} | create | atomicity | `TestNewUser_{…}` | no |
| {NewUser conflict (user exists) returns error without rollback} | create | safety | `TestNewUser_{…}` | no |
| {UpdateUser password change reaches target} | rotate | … | `TestUpdateUser_{…}` | {yes/no} |
| {Root self-rotation updates in-memory + raw config} | rotate-root | … | `TestUpdateUser_{…}` | no |
| {DeleteUser then DeleteUser again both succeed} | revoke | idempotency | `TestDeleteUser_{…}` | {yes/no} |
| {Error containing password is redacted by middleware} | all | hygiene | `TestSanitizer_{…}` | no |
| ... | | | | |

---

## 5. Security Controls

- **Secret material map**: {every config field marked Secret in §3, plus the
  request fields carrying credential material. Anything else is a bug.}
- **secretValues() list**: {exact config fields the sanitizer redacts — must
  equal the Secret=yes rows}
- **Transport**: {TLS fields, defaults, `insecure_tls` posture}
- **Root account least privilege**: {minimum target privileges mapped to the
  §2 operations}
- **Audit-safe logging**: {identifiers logged; confirmation no statement or
  secret is logged at any level}
- **Credential source**: Vault-generated (password policy) — the plugin never
  generates credential material

---

## 6. Implementation Checklist

{3-6 coarse-grained `- [ ]` items. Each declares `files:` (created or
modified; if A creates a file, B may modify but not create it),
`depends-on:` (runtime contracts, not just files: who owns client
construction, who owns the in-memory config the rotation item mutates), and
`skills:` from this CLOSED list — never invent names:
`vault-dbplugin-connection` (Initialize, config decode, client seam,
Type/Close, secretValues), `vault-dbplugin-users` (NewUser/DeleteUser,
statements, username template), `vault-dbplugin-rotation` (UpdateUser:
password/expiration/public key, root self-rotation),
`vault-dbplugin-integration-testing` (integration harness). The test-writer
creates the repo skeleton and all `_test.go` files BEFORE these items run,
including the integration harness files when §2's decision is live, so the
harness item appears ONLY then and covers wiring/polish.}

- [ ] **A: {Connection & config}** — files: {database.go, client.go}; depends-on: —; skills: vault-dbplugin-connection
- [ ] **B: {Users}** — files: {users.go}; depends-on: A {(client seam, username template)}; skills: vault-dbplugin-users
- [ ] **C: {Rotation}** — files: {rotation.go}; depends-on: A {(owns in-memory config C mutates on self-rotation)}; skills: vault-dbplugin-rotation
- [ ] **D: {Integration harness}** — files: {docker-compose.test.yml, scripts/integration-bootstrap.sh, acceptance_test.go, Makefile}; depends-on: A, B, C; skills: vault-dbplugin-integration-testing — {OMIT when §2 is fakes only}
- [ ] **E: {Polish}** — files: {README.md, Makefile}; depends-on: all; skills: —

---

## 7. Open Questions

{Deferred decisions marked [DEFERRED] with context; constitution deviations
marked [CONSTITUTION DEVIATION] with rationale. Empty if all resolved.}

---

## Template Rules

1. No section may reference another section by line number
2. Config field names appear exactly once — in §3 Config Fields
3. Statement formats appear exactly once — in §3 Statements Contract
4. §2 references target commands/APIs; §3 references the plugin interface —
   never mix; never describe Vault HTTP paths (Vault core owns them)
5. Every test scenario maps 1:1 to a named test function; §3 covers method
   behavior, §4 covers lifecycle transitions (the constitution's §6.1
   coverage table is the minimum bar)
6. §6 items are coarse-grained with explicit `files:` scope (no creation
   overlaps), `depends-on:` covering runtime contracts, and `skills:` drawn
   only from the closed list (`—` for items no activity skill covers)
7. Secret material appears ONLY where §3/§5 declare it; `secretValues()`
   must cover every Secret=yes config field
8. Scenarios needing features the runnable target tier lacks are NEVER
   marked `live?: yes`; flag the coverage conflict in §7
