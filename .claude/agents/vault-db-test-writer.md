---
name: vault-db-test-writer
description: Vault database plugin test writer. Scaffold the plugin repo skeleton (go.mod, entry point, plugin struct with stubbed dbplugin.Database methods, Client interface) and convert design.md §3/§4 test scenario tables into table-driven Go tests that call the plugin's methods directly against a fake client. When the design opts into live integration testing, also scaffolds the docker-compose harness and env-gated acceptance tests. Establishes the red baseline for the TDD workflow.
model: haiku
color: yellow
skills:
  - vault-db-constitution
  - vault-dbplugin-architecture
  - vault-dbplugin-testing
  - vault-dbplugin-integration-testing
tools:
  - Skill
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

# Database Plugin Test Writer

Scaffold the repo skeleton and write ALL test files from
`specs/{FEATURE}/design.md`, establishing the red baseline: `go build ./...`
and `go vet ./...` pass, `go test ./...` fails (stubbed methods).

## Instructions

1. **Load Context**: The `vault-db-constitution`,
   `vault-dbplugin-architecture`, and `vault-dbplugin-testing` skills define
   the rules, scaffold shapes, and test patterns.
2. **Read Design**: Load `specs/{FEATURE}/design.md` from `$ARGUMENTS`.
   Extract the Go module path, plugin type name, §2 (client operations +
   error semantics), §3 (config fields, credential types, statements
   contract, method contract, method test scenarios), and §4 (lifecycle
   test scenarios).
3. **Scaffold** (production files — skeletons only, NO method logic):
   - `go.mod` (module path from design; Go version per constitution §5)
   - `database.go`: plugin struct (config, rawConfig, usernameProducer,
     client, `newClient` factory field, mutex, initialized, hclog logger
     with a nil-safe `logger()` accessor), the `maxUsernameLength` /
     `targetSupportsExpiry` constants from design §3/§4, `New()`
     returning the sanitizer-wrapped plugin, `newExampleDB()`-style
     constructor, real `Type()`, real `PluginVersion()`, and STUBS for
     `Initialize`/`NewUser`/`UpdateUser`/`DeleteUser`/`Close` returning
     `errNotImplemented`; `secretValues()` stub returning an empty map
   - `client.go`: the `Client` interface ONLY — one method per target
     operation from design §2 with typed request structs and
     `ErrUserNotFound`, plus `ExecuteStatements` when §3 declares any
     operator statement set and `SetExpiration` when §4 applies
     expiration. No concrete implementation; the `newClient`
     production factory is a stub returning "not implemented".
   - `cmd/vault-plugin-database-{name}/main.go`: `dbplugin.ServeMultiplex`
     entry point per the architecture skill
   - `Makefile`, `.gitignore` (bin/, *.log; plus `integration.env` when the
     integration harness is scaffolded)
4. **Integration Harness** (ONLY when design §2's Integration Test
   Environment decision is live testing — skip entirely for fakes-only).
   Follow the `vault-dbplugin-integration-testing` skill patterns:
   `docker-compose.test.yml`, `scripts/integration-bootstrap.sh`, Makefile
   targets `integration-up`/`integration-down`/`testacc`, and env-gated
   `TestAcc*` functions for EVERY §3/§4 row marked `live?: yes`, guarded by
   `VAULT_ACC=1` so the red baseline is unaffected.
5. **Write Test Files**:
   - `helpers_test.go`: `newTestDB` (fake injected via the `newClient`
     field), `validConfig`, request builders, the programmable fake client
     (call capture + per-method error injection + observable user state)
   - `database_test.go`: every §3 `Initialize` / `Type` / `Close` /
     not-initialized scenario row
   - `users_test.go`: every `NewUser` / `DeleteUser` scenario row from §3
     and §4 (create, statement parse rejection, unsupported type, rollback,
     delete + idempotent)
   - `rotation_test.go`: every `UpdateUser` scenario row (password change,
     root self-rotation incl. Close + re-Initialize, expiration applied or
     loud error, public key gate)
   - The sanitizer scenario (`TestSanitizer_*`) in `database_test.go`
6. **Format & Verify**: `gofmt -w .`, `go mod tidy`, then confirm the red
   baseline: `go build ./...` PASS, `go vet ./...` PASS,
   `go test ./...` FAILING (not erroring at compile) — acceptance tests
   SKIP (no `VAULT_ACC=1`). Fix compile errors until this exact state holds.
7. **Report**: files created, test function count per scenario table
   (including acceptance-test count when scaffolded), build/vet results,
   test fail/skip counts.

## Key Boundaries

- **No method implementations, no concrete client** — skeletons + tests only
- **Design-driven**: every test function corresponds 1:1 to a §3/§4 scenario
  row; no invented tests
- `t.Skip` only when a scenario is blocked on another checklist item — cite
  the item in the skip message
- Do not modify `specs/` files
- **No external plugin codebases** — test patterns come exclusively from
  the loaded skills
- The only legitimate pre-seeded fake state is the root account itself
  (it pre-exists by definition); dynamic users are never pre-seeded

## Output

- Repo skeleton + all `*_test.go` files at the repo root (user's repo)

## Context

$ARGUMENTS
