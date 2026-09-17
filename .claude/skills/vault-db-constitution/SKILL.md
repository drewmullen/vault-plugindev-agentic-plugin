---
name: vault-db-constitution
description: Non-negotiable principles for generating Vault database plugins in Go — the public dbplugin v5 Database interface, error-sanitizer middleware, client interface seam, config and statement contracts, secret hygiene, credential lifecycle (NewUser/UpdateUser/DeleteUser incl. root self-rotation), testing and validation gates. Load before designing, generating, or reviewing any database plugin code.
user-invocable: false
---

# Vault Database Plugin Development Constitution

**Version**: 0.1.0
**Effective Date**: September 2026
**Purpose**: Non-negotiable principles for generating Vault database plugins (`dbplugin.Database`) in Go
**Authority**: This document governs what correct plugin code looks like. Workflow mechanics live in orchestrator skills. Agent behavior lives in AGENTS.md. If a rule exists here, it is not duplicated elsewhere.
**Sources**: Built exclusively from public HashiCorp documentation (developer.hashicorp.com/vault, the `hashicorp/vault/sdk` godoc, the MPL-licensed `hashicorp/vault` builtin database backend) and public open-source plugin repos (`hashicorp/vault-plugin-database-redis`, `hashicorp/vault-plugin-database-elasticsearch`, `hashicorp/vault-plugin-database-couchbase`, and the in-tree `hashicorp/vault/plugins/database/*`).

---

## 0. What a Database Plugin Is (and Is Not)

Vault's **combined database secrets engine** (`vault secrets enable database`)
owns every HTTP path: `config/<name>`, `roles/<name>`, `creds/<name>`,
`static-roles/<name>`, `static-creds/<name>`, `rotate-root/<name>`,
`rotate-role/<name>`, `reset/<name>`. It owns leases, TTL resolution,
password generation (password policies), username-metadata sanitizing, the
rotation scheduler, WAL entries around rotation, and Enterprise gating.

A database plugin is the **per-database executor** behind that engine. It
implements exactly one interface and nothing else:

```go
type Database interface {
    Initialize(ctx, InitializeRequest) (InitializeResponse, error)
    NewUser(ctx, NewUserRequest) (NewUserResponse, error)
    UpdateUser(ctx, UpdateUserRequest) (UpdateUserResponse, error)
    DeleteUser(ctx, DeleteUserRequest) (DeleteUserResponse, error)
    Type() (string, error)
    Close() error
}
```

Consequences that shape every rule below:

- There are **no `framework.Path`s, no `framework.Secret`s, no storage
  entries, and no WAL** in a database plugin. Anything a design places there
  is a scope error.
- Vault **supplies** the password (or public key / certificate subject); the
  plugin never generates credential material.
- Vault calls the plugin over gRPC. Error *types* do not survive the
  boundary — only the sanitized message string does.

---

## 1. Core Principles

### 1.1 Public SDK, v5 Interface Only

- Plugins MUST implement `github.com/hashicorp/vault/sdk/database/dbplugin/v5`'s `Database` interface; the v4 interface and `builtin/logical/database` MUST NOT be imported
- The plugin MUST expose a `New() (interface{}, error)` factory that returns the implementation wrapped in `dbplugin.NewDatabaseErrorSanitizerMiddleware(db, db.secretValues)`
- The entry point (`cmd/vault-plugin-database-<name>/main.go`) MUST use `dbplugin.ServeMultiplex(New)` (one process, many connections)
- The plugin SHOULD implement `logical.PluginVersioner` (`PluginVersion() logical.PluginVersion`) so the catalog self-reports its version
- `Type()` MUST return a stable lowercase identifier used for logs/metrics
- `go.mod` MUST NOT contain `replace` directives; the enterprise SDK and `vault-licensing` MUST NOT be imported

### 1.2 Single Narrow Client Interface

All access to the target database goes through ONE Go interface (conventionally in `client.go`).

- `Initialize`/`NewUser`/`UpdateUser`/`DeleteUser` MUST NOT drive a driver, SDK, or HTTP directly — they call the client interface
- The interface MUST expose only the operations the plugin needs (ping, create user, set password, set expiration, delete user, …)
- Client construction from decoded config MUST be a single injectable factory (`newClient func(config) (Client, error)` field on the plugin struct) so tests substitute a fake without touching production code
- SQL targets MAY satisfy the seam by wrapping `connutil.SQLConnectionProducer` behind the interface; the interface still exists

### 1.3 Secret Hygiene

Secret material MUST never appear in logs, error strings, struct `String()` methods, or responses beyond what the interface returns.

- `secretValues()` MUST map EVERY secret config value (password, private key, client key, bearer token, …) to a bracketed placeholder so the sanitizer middleware redacts them from every error; empty values MUST be skipped (an empty key would corrupt the redaction)
- Error strings MUST NOT embed statement bodies, request bodies, or response bodies — statements carry `{{password}}` substitutions
- `NewUserResponse` carries ONLY `Username`; the plugin never returns the password (Vault already has it)
- `InitializeResponse.Config` MUST be the request config (possibly with defaults filled in) — Vault persists it as `connection_details`; the plugin MUST NOT add secret material Vault did not supply, and MUST NOT strip fields Vault needs on re-initialize
- Log lines MAY include usernames, hosts, and role names; never statements, passwords, or keys

### 1.4 Tests Before Implementation

Test files are written before the methods are implemented. Because Go cannot run tests against code that does not compile, the red baseline is: `go build ./...` and `go vet ./...` pass, `go test ./...` fails or skips.

- The scaffold declares the plugin struct and all six interface methods as stubs returning a "not implemented" error, plus the `Client` interface; tests compile against these and fail until items land
- Every method MUST have table-driven tests calling it directly on the plugin with a fake client — no test may talk to a real database
- Unimplemented functionality is represented by failing or explicitly skipped tests, never by missing tests

### 1.5 Single Design Document

All planning produces one file: `specs/{FEATURE}/design.md` (7 sections; checklist in §6).

- Config fields, statement contracts, method contracts, lifecycle behavior, and test scenarios each appear exactly once
- No separate specification, plan, contract, or task files

---

## 2. Code Standards

### 2.1 File Organization

```
<repo root>/                              # package <name> (e.g. acmedb)
├── database.go                           # plugin struct, New(), Initialize, Type, Close, secretValues, PluginVersion
├── database_test.go
├── client.go                             # Client interface + concrete implementation + newClient factory
├── client_test.go
├── users.go                              # NewUser, DeleteUser, statement parsing, username generation
├── users_test.go
├── rotation.go                           # UpdateUser: password / expiration / public key, root self-rotation
├── rotation_test.go
├── helpers_test.go                       # newTestDB, fake client, request builders
├── acceptance_test.go                    # env-gated live tests (only when the design opts in)
├── cmd/vault-plugin-database-<name>/main.go   # dbplugin.ServeMultiplex entry point
├── go.mod / go.sum
├── Makefile                              # build, test, fmt, vet, dev (+ integration targets when opted in)
└── README.md
```

Rules:

- One concern per file with its `_test.go` sibling; no file over ~500 lines
- The plugin struct holds the decoded config, the raw config map, the username template, the client, the client factory, and one mutex — no global state
- Statement parsing helpers live with the method that consumes them (`users.go`), not in a grab-bag `util.go`

### 2.2 Naming

- Package name: `<name>` or `<name>db` (e.g. `acmedb`); exported plugin type `<Name>DB` (e.g. `AcmeDB`)
- Type identifier: `Type()` returns the lowercase target name (`"acme"`)
- Config struct: `<name>Config` with `mapstructure` tags matching the operator-facing field names exactly (`connection_url`, `username`, `password`, `username_template`, …)
- Test functions: `TestInitialize_*`, `TestNewUser_*`, `TestUpdateUser_*`, `TestDeleteUser_*`, `TestSanitizer_*` — table-driven inside
- Names MUST follow Go conventions and MUST NOT contain secrets or PII

### 2.3 Config Contract

- `Initialize` MUST decode `req.Config` into the typed config struct (`mapstructure`, weak decode) and validate required fields BEFORE constructing a client; validation errors name the field, never its value
- Fields Vault strips before calling the plugin (`plugin_name`, `plugin_version`, `verify_connection`, `allowed_roles`, `root_rotation_statements`, `password_policy`, rotation scheduling fields) MUST NOT be expected by the plugin
- `username_template` MUST be honored: compile with `sdk/helper/template`, fall back to the plugin's documented default, and reject a template that fails a test render at `Initialize` time
- `req.VerifyConnection == true` MUST perform a real round-trip through the client (ping / trivial read); `false` MUST skip it — Vault relies on this for `verify_connection=false` configs
- The response MUST call `SetSupportedCredentialTypes` with the exact set the plugin implements; `NewUser`/`UpdateUser` MUST reject any other `CredentialType` with a clear error

### 2.4 Statement Contract

- The design §3 statements table is the single source of truth for the format of `creation_statements`, `revocation_statements`, `rotation_statements`, `renew_statements`, and `rollback_statements`
- SQL-shaped targets substitute `{{name}}`, `{{username}}`, `{{password}}`, `{{expiration}}` via `dbutil.QueryHelper` and execute inside one transaction with rollback on failure
- Non-SQL targets define a JSON statement schema; parse errors are returned with the offending key named (never the value)
- Empty statements MUST behave as the design declares: either a documented default (e.g. default revocation deletes the user) or `dbutil.ErrEmptyCreationStatement`

### 2.5 Error Handling

- Every error returned across the interface MUST be wrapped with `%w` and operation context (`"failed to create user %q: %w"`)
- Not-found on delete MUST be swallowed (idempotent revoke); every other target failure MUST surface
- Do not depend on `errors.Is`/`errors.As` on the Vault side — the gRPC boundary flattens errors; encode intent in the message
- A non-initialized plugin MUST return `connutil.ErrNotInitialized` (or an equivalent stable message) from every method except `Type` and `Close`

### 2.6 Locking

- One `sync.RWMutex` on the plugin struct guards config, client, and template — no package-level mutable state
- **Write lock** for the operations that swap the client or credential: `Initialize` (held for the whole method, including the verify ping — a concurrent `NewUser` must never borrow a half-swapped client), `Close`, and root-password adoption after a self-rotation
- **Read lock** for `NewUser`/`UpdateUser`/`DeleteUser`, held for the whole call including the target round-trip; readers do not block each other, and the lock only prevents the client being closed or replaced underneath an in-flight operation
- The write lock MUST NOT be held across a user-facing target mutation: root self-rotation changes the password under the read lock, releases it, and only then takes the write lock to adopt the new credential
- If the target client is not safe for concurrent use, the design MUST say so and the operation methods take the write lock instead

---

## 3. Security and Compliance

### 3.1 Secret Material Boundaries

- Secrets exist in: the `password`/key fields of the config Vault passes in, `NewUserRequest.Password`/`PublicKey`, `ChangePassword.NewPassword`, `ChangePublicKey.NewPublicKey`, and `UpdateUserRequest.SelfManagedPassword` — nowhere else
- The plugin MUST NOT persist anything to disk or to Vault storage; state lives in memory for the life of the connection
- The plugin MUST NOT generate passwords or keys; if a target needs an internal random value (e.g. a role name suffix) use `base62.Random`, never `math/rand`

### 3.2 Sanitizer Coverage

- `secretValues()` MUST be tested: inject a target error containing the configured password and assert the wrapped plugin's error does not contain it
- Adding a new secret config field without extending `secretValues()` is a P0 defect

### 3.3 Transport Security

- Any TLS material (`ca_cert`, `client_cert`, `client_key`, `tls_server_name`, `insecure_tls`) accepted in config MUST be applied to the client; `insecure_tls` MUST default to false and be reported in the design §5 as a documented operator choice
- Plaintext credentials over an unencrypted transport MUST be flagged in the README

### 3.4 Root Account Least Privilege

- README and design §5 MUST document the minimum target-side privileges the configured root account needs (create/alter/drop users, grant the roles the statements reference)
- The plugin MUST NOT require broader privileges than its implemented operations

### 3.5 Audit-Safe Logging

- No statement text, password, key, or connection URL containing credentials may be logged at any level
- Log identifiers only: username, role name, target host

---

## 4. Credential Lifecycle

### 4.1 NewUser (dynamic credentials)

- Username generation MUST use the compiled username template with `req.UsernameConfig` as data, then enforce the target's length/charset limits (truncate/lowercase per design)
- Creation MUST be atomic-or-rolled-back: on failure after the user exists, run `RollbackStatements` if present, else best-effort delete the user, then return the original error
- A conflict on create (the target reports the username already exists, surfaced by the client as `ErrUserExists`) MUST NOT trigger rollback — that account is not the plugin's to delete; return the error naming the username
- `req.Expiration` MUST be applied when the target supports account expiry and the design says so; otherwise the design documents that Vault's lease is the only expiry
- Unsupported `CredentialType` → error before any target mutation

### 4.2 DeleteUser (revocation)

- MUST be idempotent: a user that no longer exists is success
- MUST honor `req.Statements` when present and fall back to the documented default revocation otherwise
- MUST NOT depend on any per-user state cached in the plugin (Vault may call it on a fresh process)

### 4.3 UpdateUser (rotation, renewal)

- `req.Password != nil` → change the password using `req.Password.Statements` if present, else the documented default
- `req.Expiration != nil` → extend expiry when supported; when unsupported the design MUST say whether the call errors or no-ops (an error is the safe default: it makes a misconfigured `renew_statements` visible)
- `req.PublicKey != nil` → only when `CredentialTypeRSAPrivateKey` is in the supported set
- **Root self-rotation**: when `req.Username` equals the configured root username, after the target accepts the new password the plugin MUST update its in-memory config AND raw config map so the live client keeps authenticating; Vault then persists the new password to `connection_details`, calls `Close`, and re-`Initialize`s on next use — the plugin MUST survive that sequence without an operator action
- `SelfManagedPassword` (Enterprise): the design MUST state whether the plugin honors it (authenticate as the user to change its own password) or ignores it; ignoring MUST be documented, never silent

### 4.4 Enterprise-Dependent Behavior (Degradable)

Automated root rotation, static-role rotation scheduling, `skip_import_rotation`, and `self_managed_password` are implemented by **Vault core** and gated there; the plugin sees only `UpdateUser` calls.

- The plugin MUST behave identically whether a rotation was manual or scheduled — it cannot tell the difference and MUST NOT try to
- Every §4 Enterprise-Dependent row in the design states what the plugin does when the feature is off (typically: nothing changes; those `UpdateUser` calls simply never arrive)

---

## 5. Version and Dependency Management

- `go.mod` MUST declare a Go version >= 1.24
- Allowed dependencies: `hashicorp/vault/sdk`, `hashicorp/go-hclog`, `hashicorp/go-secure-stdlib/*`, `mitchellh/mapstructure`, the target's official Go driver/SDK (or stdlib `net/http`/`database/sql`), and `stretchr/testify` for tests
- `go mod tidy` manages dependencies; the module MUST build with `GOFLAGS=-mod=readonly`
- Semantic versioning with `v`-prefixed git tags; every PR carries exactly one `semver:*` label

---

## 6. Testing and Validation

### 6.1 Test Coverage

Every plugin MUST have tests covering:

| Scenario | Purpose |
|----------|---------|
| Initialize: valid config | Config decoded, template compiled, client built, response echoes config + supported types |
| Initialize: missing/invalid field | Error names the field, no client constructed |
| Initialize: verify_connection on/off | Ping called exactly when true; ping failure fails init |
| Initialize: bad username_template | Rejected at config time |
| NewUser: happy path | Username matches template, target received password/roles/expiration, response has only Username |
| NewUser: statement parse error | Rejected before any target call |
| NewUser: unsupported credential type | Rejected before any target call |
| NewUser: target failure after create | Rollback/delete attempted; original error returned |
| NewUser: username conflict | No rollback/delete issued; error returned; existing user untouched |
| UpdateUser: password change | Target received new password with rotation statements/default |
| UpdateUser: root self-rotation | In-memory config and raw config updated; client re-authenticates |
| UpdateUser: expiration | Applied, or documented error when unsupported |
| DeleteUser: happy + idempotent | Second delete of a gone user succeeds |
| Sanitizer | Target error containing the password is redacted through the middleware |
| Not initialized | Methods error before Initialize |
| Type/Close | Stable type string; Close releases the client and is idempotent |

### 6.2 Validation Pipeline

Every checkpoint MUST pass `gofmt -l` (empty) and `go vet ./...`. Before PR, the full pipeline:

| Check | Tool | Blocks PR |
|-------|------|:-:|
| Formatting | `gofmt -l .` | Yes |
| Static analysis | `go vet ./...` | Yes |
| Compilation | `go build ./...` | Yes |
| Unit tests | `go test -race ./...` | Yes |
| Lint | `golangci-lint run` (if installed) | Advisory |
| Dev-server smoke | register in `sys/plugins/catalog/database`, `secrets enable database`, write `config/<name>` with `verify_connection=false` (if vault installed) | Advisory |

### 6.3 Test Isolation

- Unit tests call plugin methods directly with a fake `Client` injected through the `newClient` factory — no network, no containers
- Fakes MUST be programmable per-test (inject errors per method, capture calls, hold observable user state)
- Env-gated acceptance tests (`VAULT_ACC=1`) against a disposable container are an opt-in separate layer per `vault-dbplugin-integration-testing`

---

## 7. Change Management

### 7.1 Git Workflow

- Direct commits to `main` PROHIBITED in generated repos; all changes via `NNN-<short-name>` feature branches
- MUST NOT commit secrets, credentials, `.env`, or `integration.env`; test fixtures use generated values
- Checkpoint commits after every workflow step via `checkpoint-commit.sh`

### 7.2 Design Approval

The workflow MUST pause between Design (Phase 2) and Implement (Phase 3) for human review of `design.md`.

### 7.3 Quality Gates Between Phases

| Gate | Condition |
|------|-----------|
| Clarify -> Design | Credential features, statement format, and security defaults resolved. No unresolved `[NEEDS CLARIFICATION]` markers. |
| Design -> Implement | Design document approved by a human. |
| Red baseline -> Items | `go build ./...` and `go vet ./...` pass; tests fail/skip as expected. |
| Implement -> Validate | All design §6 checklist items `[x]`; full `go test ./...` passes. |
| Validate -> PR | All blocking checks in Section 6.2 pass. |

---

## 8. Governance

- This constitution is maintained in version control; amendments via pull request
- Deviations require: a documented driving requirement, an alternative with risk assessment, and the deviation recorded in design §7 (Open Questions) or code comments
- All generated code — AI-generated or human-edited — passes through the same validation pipeline
