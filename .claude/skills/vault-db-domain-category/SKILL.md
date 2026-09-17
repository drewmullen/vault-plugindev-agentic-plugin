---
name: vault-db-domain-category
description: 8-category ambiguity taxonomy for Vault database plugin (dbplugin.Database) specifications. Structured scan methodology, prioritization heuristics, and clarification question patterns. Use when scanning database plugin requirements for ambiguity, missing decision points, or underspecified requirements.
user-invocable: false
---

# Vault Database Plugin Specification Ambiguity Taxonomy

## Purpose

Detect and reduce ambiguity or missing decision points in database plugin
requirements. Each category is scanned and marked: Clear / Partial / Missing.

Framing reminder for every category: Vault core owns the HTTP paths, leases,
password generation, and rotation scheduling. The plugin only executes
`Initialize`, `NewUser`, `UpdateUser`, `DeleteUser`. Questions about Vault
paths, TTL defaults, or seal wrap are out of scope here — they belong to the
operator's `database/` mount configuration, not the plugin.

## 8-Category Taxonomy

### 1. Functional Scope & Behavior

- Which system's users the plugin manages and what "a user" is there
  (account, role, API principal, ACL entry)
- Core success criteria ("`vault read database/creds/<role>` yields a login
  that works against the target with the granted permissions")
- Explicit out-of-scope declarations (e.g. no static roles, no expiration)
- **Shape check**: if the target has no notion of managed users and the
  request is really "mint an API token", it is a logical secrets engine
  (`/vault-secrets-plan`), not a database plugin — flag it first

### 2. Credential Features & Types

- **Dynamic users** (NewUser/DeleteUser) — always; **static-role rotation**
  (UpdateUser password) — usually; **renewal** (UpdateUser expiration) —
  only if the target has account expiry; **root self-rotation** — should be
  supported unless the root account cannot change its own password
- Credential types: password only vs. rsa_private_key vs. client_certificate
  — what can the target authenticate with?
- What a "role" means in the target and how creation statements express it

### 3. Statements & Username Contract

- Statement format: SQL templates (`{{name}}`, `{{password}}`,
  `{{expiration}}`), a JSON schema (`{"roles":[…]}`), or none (plugin
  applies defaults)
- Behavior when statements are empty: sensible default vs. hard error
- Username constraints: max length, charset, case, reserved prefixes; the
  default `username_template`
- Which statement sets exist at all (creation / revocation / rotation /
  renew / rollback) for this target

### 4. Non-Functional Quality Attributes

- Concurrency: is the target client safe for parallel NewUser calls?
- Connection pooling / reuse across calls; connection lifetime; `Close`
  semantics
- Observability (identifiers logged — never statements or secrets)
- Multiplexing: one plugin process serving many `config/<name>` connections
  (default via `ServeMultiplex`)

### 5. Integration & External Dependencies

- Root connection model (user/password, token, mTLS, cloud IAM) and how the
  root account is provisioned with least privilege
- Admin operations for each lifecycle step; whether "user exists" on create
  and "not found" on delete are errors
- Client choice: `database/sql` driver via `connutil` vs. official Go SDK vs.
  plain `net/http`
- TLS options the operator needs (`ca_cert`, client cert/key, `insecure_tls`)

### 6. Edge Cases & Failure Handling

- NewUser fails after the user exists (grant failed) — rollback statements
  vs. best-effort delete
- Root self-rotation: target accepts new password but client rebuild fails;
  Vault re-Initializes with the new password on next use
- Static rotation retried by Vault with the same password after a transient
  failure (must be idempotent)
- Renewal requested (`renew_statements` set) on a target without expiry
- Target unreachable at `Initialize` with `verify_connection=false`

### 7. Constraints & Tradeoffs

- Enterprise features live in Vault core (automated rotation,
  `self_managed_password`, `skip_import_rotation`): the plugin must behave
  identically either way — does the plugin honor `SelfManagedPassword`?
- Go module path — GitHub org/user name (required to scaffold `go.mod`)
- Go/SDK version constraints; explicit rejected alternatives

### 8. Terminology & Consistency

- Canonical config field names (`connection_url` vs `url` vs `hosts`);
  match the public plugins' conventions where the target has precedent
- Consistent naming for the plugin type string, the module, the binary
  (`vault-plugin-database-<name>`), and the catalog entry

## Bonus Categories (check but lower priority)

- **Completion Signals**: acceptance criteria testability, measurable DoD indicators
- **Misc / Placeholders**: TODO markers, ambiguous adjectives ("secure",
  "short-lived", "least privilege") lacking quantification

## Prioritization Heuristic

Rank by `Impact x Uncertainty`:

- High impact + high uncertainty → ask first
- Low impact regardless of uncertainty → skip or defer
- Categories already Clear → skip entirely

## Question Constraints

- Maximum 5 questions per session
- Three question slots are **mandatory** and count toward the maximum:
  1. **Credential features** — dynamic only / + static rotation / + renewal
     (expiration) / + root self-rotation; and credential types
  2. **Statements contract** — SQL templates / JSON schema / defaults-only,
     and the empty-statements behavior
  3. **Security defaults** — TLS posture (`insecure_tls` default false,
     CA/cert fields), `verify_connection` expectations, root-account
     privilege scope: apply proposed defaults or customize
- If the Go module path is unknown, the GitHub org/user question is also
  mandatory
- The integration-environment question is asked whenever the target can be
  containerized
- Each question must be answerable with multiple-choice (2-5 options) or a
  short answer (≤5 words)
- Only include questions whose answers materially impact: config fields,
  statement format, method behavior, test design, or security posture

## Question Exclusions

- Already answered in the request
- Anything Vault core decides (TTLs, lease behavior, password policy, paths)
- Trivial stylistic preferences
- Implementation-level details that don't block design (unless correctness-blocking)

## Database-Plugin Focus Areas

When scanning database plugin specs, pay special attention to:

- Whether the target actually has managed users (shape check)
- Expiration support — it decides whether renewal is an error or a feature
- Statement format and empty-statement behavior (drives NewUser/DeleteUser tests)
- Root self-rotation feasibility (can the root account change its own password?)
- Username limits (silent truncation is a classic bug)
- `SelfManagedPassword` handling (honor vs. documented ignore)
