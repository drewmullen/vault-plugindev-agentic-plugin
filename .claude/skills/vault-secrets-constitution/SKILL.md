---
name: vault-secrets-constitution
description: Non-negotiable principles for generating Vault secrets engine plugins in Go — public SDK usage, client interface seam, secret hygiene, storage schema, credential lifecycle, WAL crash safety, Rotation Manager degradation, testing and validation gates. Load before designing, generating, or reviewing any secrets engine code.
user-invocable: false
---

# Vault Secrets Engine Development Constitution

**Version**: 0.1.0
**Effective Date**: July 2026
**Purpose**: Non-negotiable principles for generating Vault secrets engine plugins in Go
**Authority**: This document governs what correct plugin code looks like. Workflow mechanics live in orchestrator skills. Agent behavior lives in AGENTS.md. If a rule exists here, it is not duplicated elsewhere.
**Sources**: Built exclusively from public HashiCorp documentation (developer.hashicorp.com/vault, `hashicorp/vault/sdk` godoc) and public open-source plugin repos (`vault-plugin-secrets-openldap`, `vault-plugin-secrets-terraform`).

---

## 1. Core Principles

### 1.1 Public SDK, Framework First

Plugins MUST be built on the public [`github.com/hashicorp/vault/sdk`](https://pkg.go.dev/github.com/hashicorp/vault/sdk) using `framework.Backend`.

- The backend MUST be constructed via a `Factory(ctx, *logical.BackendConfig)` function that calls `b.Setup(ctx, conf)` and returns `logical.Backend`
- `BackendType` MUST be `logical.TypeLogical`
- Paths MUST be declared as `framework.Path` entries composed with `framework.PathAppend`
- The entry point (`cmd/<plugin-name>/main.go`) MUST use `plugin.ServeMultiplex` with `api.VaultPluginTLSProvider` per current public SDK guidance
- `go.mod` MUST NOT contain `replace` directives; the enterprise SDK and `vault-licensing` MUST NOT be imported
- Every path MUST define `HelpSynopsis`/`HelpDescription` and OpenAPI `DisplayAttrs` with a consistent operation prefix

### 1.2 Single Narrow Client Interface

All access to the external system goes through ONE Go interface (conventionally in `client.go`).

- Path handlers MUST NOT make HTTP/SDK calls directly — they call the client interface
- The interface MUST expose only the operations the engine needs (least surface)
- The concrete client is injected in `Factory`/`Backend()` so tests substitute a fake
- Client construction from stored config MUST be centralized (one `getClient`-style helper), guarded for concurrent use

### 1.3 Secret Hygiene

Secret material MUST never appear in logs, error strings, Go struct `String()` methods, or responses outside what the design declares.

- `creds/` (and rotation) responses contain ONLY the fields declared in design §3 — nothing else, ever
- Config read responses MUST omit credentials (return the username/URL, never the password/token/key)
- Error messages and log lines MAY include identifiers (role name, host, username) but MUST NOT include secret values, request bodies, or response bodies that could carry secrets

### 1.4 Tests Before Implementation

Test files are written before path handlers are implemented. Because Go cannot run tests against code that does not compile, the red baseline is: `go build ./...` and `go vet ./...` pass, `go test ./...` fails or skips.

- Every path handler MUST have table-driven tests exercising it through the backend (`logical.Request` against a test backend with `logical.InmemStorage`)
- Tests MUST use a fake client — no test may talk to a real external API
- Unimplemented functionality is represented by failing or explicitly skipped tests, never by missing tests

### 1.5 Single Design Document

All planning produces one file: `specs/{FEATURE}/design.md` (7 sections; checklist in §6).

- Paths, storage entries, lifecycle behavior, and test scenarios each appear exactly once
- No separate specification, plan, contract, or task files
- The design document is the sole source of truth for the implementation

---

## 2. Code Standards

### 2.1 File Organization

Plugins MUST follow the flat, path-per-file layout used by public HashiCorp plugins:

```
<repo root>/                        # package <engine>secrets (or similar)
├── backend.go                      # Factory, Backend(), backend struct, help text
├── client.go                       # client interface + concrete implementation
├── client_test.go
├── path_config.go                  # config endpoint(s)
├── path_config_test.go
├── path_<resource>.go              # one file per path family (roles, creds, rotate, ...)
├── path_<resource>_test.go
├── secret_<name>.go                # framework.Secret definition (dynamic credentials)
├── helpers_test.go                 # shared test harness (getBackend, fake client)
├── cmd/<plugin-name>/main.go       # plugin.ServeMultiplex entry point
├── go.mod / go.sum
├── Makefile                        # build, test, fmt, dev targets
└── README.md
```

Rules:

- One path family per `path_*.go` file with its `_test.go` sibling
- Hierarchical resources (child under parent, e.g. accounts under hosts) keep the child's paths in their own file named for the child
- The backend struct holds the framework backend, client, and any locks — no global state
- No single file may exceed ~500 lines; split by path family

### 2.2 Naming

- Package name: `<engine>secrets` (e.g. `gitlabsecrets`)
- Path builders: `(b *backend) pathConfig()`, `pathRoles()`, `pathCreds()` returning `[]*framework.Path`
- Handlers: `pathConfigWrite`, `pathRoleRead`, `pathCredsCreate` — `path<Family><Operation>`
- Storage keys: lowercase constants (`configPath = "config"`, `rolePrefix = "roles/"`)
- Test functions: `TestConfig_Write`, `TestRole_CRUD`, `TestCreds_Issue` — table-driven inside
- Names MUST follow Go conventions and MUST NOT contain secrets or PII

### 2.3 Storage Schema

- Storage entries MUST be typed Go structs serialized with `logical.StorageEntryJSON`
- The schema MUST be deterministic and versioned: each entry struct carries a `Version int` field (or the design documents why not), with an explicit upgrade path for future changes
- Storage reads MUST tolerate missing entries (return nil, not error) and reject unknown versions with a clear error
- WAL entries MUST live under `framework.WALPrefix` and be declared `LocalStorage` in `PathsSpecial`

### 2.4 Request Handling

- Field schemas MUST declare `Type`, `Description`, and `Required`/default per field
- User-input errors MUST return `logical.ErrorResponse(...)` (HTTP 4xx semantics) with a `nil` Go error
- Internal/external-system failures MUST return a Go error (HTTP 5xx semantics), wrapped with `%w` and context
- Existence checks MUST be implemented for any path supporting Create vs Update semantics
- Handlers touching shared state MUST use per-key locks (`locksutil` or equivalent), never a single global mutex for unrelated keys

---

## 3. Security and Compliance

### 3.1 Secret Material Boundaries

- Secrets returned to callers appear ONLY in `creds/` responses (dynamic) or explicitly designed rotation/read endpoints (static), exactly as declared in design §3
- Secrets at rest appear ONLY in the storage entries declared in design §3
- Generated passwords MUST use `base62.Random` or the mount's configured password policy (`System().GeneratePasswordFromPolicy`) — never `math/rand`

### 3.2 Seal Wrap

- Design §5 MUST list every storage path that holds secret material as a seal-wrap candidate
- Paths storing root/config credentials MUST be included in `PathsSpecial.SealWrapStorage`

### 3.3 Root Credential Least Privilege

- The engine's README and design §5 MUST document the minimum API scopes/permissions the configured root credential needs
- The plugin MUST NOT require broader scopes than the operations it implements

### 3.4 Audit-Safe Logging

- No secret value may be logged at any level, including debug and trace
- Log identifiers (role, host, account, request path), never credential values
- External API request/response bodies MUST NOT be logged wholesale

---

## 4. Credential Lifecycle

### 4.1 Leases and Dynamic Credentials

- Dynamic credentials MUST be issued through a `framework.Secret` with `Renew` and `Revoke` functions
- TTLs MUST respect role-level and mount-level maximums via the framework's TTL resolution; defaults are declared in design §4
- Revocation MUST be idempotent: revoking an already-deleted external credential succeeds
- Internal secret data MUST carry everything revocation needs — revocation MUST NOT depend on role config still existing

### 4.2 Rotation and Crash Safety

- Any multi-step operation that mutates the external system (rotate, create-then-store) MUST write a WAL entry before the external call and delete it only after storage is consistent
- WAL rollback/tidy logic MUST make rotation recoverable: on plugin restart, incomplete rotations are reconciled
- Rotation MUST generate the new secret, apply it externally, then persist — with the failure mode at each step documented in design §4
- Write-ordering: never persist a credential that was not successfully set externally, and never lose track of one that was

### 4.3 Rotation Manager (Enterprise-Dependent, Degradable)

- Automated rotation MUST be implemented via the framework's `RotateCredential` callback and the SDK's automated rotation parameters
- Rotation Manager scheduling is a Vault Enterprise feature: the plugin MUST expose configuration to leave automated rotation disabled (the default), and manual rotation endpoints MUST work identically on OSS Vault
- The plugin MUST load and function fully on OSS Vault with automated rotation off; it MUST NOT gate unrelated functionality on Enterprise detection or licensing
- Every Enterprise-dependent feature MUST state in design §4: what it depends on, how it is disabled, and what disabled behavior looks like
- Tests MUST cover both enabled and disabled modes

---

## 5. Version and Dependency Management

- `go.mod` MUST declare a Go version >= 1.24
- Allowed dependencies: `hashicorp/vault/sdk`, `hashicorp/vault/api`, `hashicorp/go-hclog`, `hashicorp/go-secure-stdlib/*`, the target system's official Go SDK (or stdlib `net/http`), and `stretchr/testify` for tests
- Dependencies MUST be managed via `go mod tidy`; the module MUST build with `GOFLAGS=-mod=readonly`
- Semantic versioning with `v`-prefixed git tags; every PR carries exactly one `semver:*` label

---

## 6. Testing and Validation

### 6.1 Test Coverage

Every engine MUST have tests covering:

| Scenario | Purpose |
|----------|---------|
| Config CRUD | Write/read/delete config; read never returns secrets |
| Role/resource CRUD | Create, read, update, delete, list for each path family |
| Credential issue | `creds/` returns exactly the designed fields with correct TTLs |
| Renew | Lease renewal respects role and mount maximums |
| Revoke | External credential removed; idempotent on repeat |
| Rotate | Manual rotation succeeds; WAL written and cleared |
| Rotation failure | External failure mid-rotation leaves recoverable state |
| Enterprise modes | Automated rotation enabled and disabled both work |
| Validation | Invalid inputs rejected via `logical.ErrorResponse` with actionable messages |

### 6.2 Validation Pipeline

Every checkpoint MUST pass `gofmt -l` (empty) and `go vet ./...`. Before PR, the full pipeline:

| Check | Tool | Blocks PR |
|-------|------|:-:|
| Formatting | `gofmt -l .` | Yes |
| Static analysis | `go vet ./...` | Yes |
| Compilation | `go build ./...` | Yes |
| Unit + backend tests | `go test -race ./...` | Yes |
| Lint | `golangci-lint run` (if installed) | Advisory |
| Dev-server smoke mount | `vault server -dev -dev-plugin-dir` (if vault installed) | Advisory |

### 6.3 Test Isolation

- Tests use `logical.InmemStorage` and a fake client — no network, no dockertest (fakes only for now)
- Fakes MUST be programmable per-test (inject errors, capture calls) to cover failure paths
- Tests MUST NOT share mutable state; parallel-safe where possible

---

## 7. Change Management

### 7.1 Git Workflow

- Direct commits to `main` PROHIBITED in generated repos; all changes via `NNN-<short-name>` feature branches
- MUST NOT commit secrets, credentials, or `.env` files; test fixtures use generated values
- Checkpoint commits after every workflow step via `checkpoint-commit.sh`

### 7.2 Design Approval

The workflow MUST pause between Design (Phase 2) and Implement (Phase 3) for human review of `design.md`.

- Gate signal: explicit approval from the user (or an "approved"/"proceed" comment on the tracking issue when one exists)

### 7.3 Quality Gates Between Phases

| Gate | Condition |
|------|-----------|
| Clarify -> Design | Credential model and security defaults resolved. No unresolved `[NEEDS CLARIFICATION]` markers. |
| Design -> Implement | Design document approved by a human. |
| Red baseline -> Items | `go build ./...` and `go vet ./...` pass; tests fail/skip as expected. |
| Implement -> Validate | All design §6 checklist items `[x]`; full `go test ./...` passes. |
| Validate -> PR | All blocking checks in Section 6.2 pass. |

---

## 8. Governance

- This constitution is maintained in version control; amendments via pull request
- Deviations require: a documented driving requirement, an alternative with risk assessment, and the deviation recorded in design §7 (Open Questions) or code comments
- All generated code — AI-generated or human-edited — passes through the same validation pipeline
