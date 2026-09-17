---
name: vault-report-template
description: Validation results summary template for Phase 4 output of the secrets engine and database plugin workflows. Provides the format for reporting gofmt, go vet, go build, go test -race, golangci-lint, dev-server smoke mount, design conformance, and quality score results, with a per-workflow coverage table.
user-invocable: false
---

# Validation Results Report Template

Phase 4 output format. Report validation results only — no resource tracking,
token usage, or workaround logs.

## Report Location

`specs/{FEATURE}/reports/validation_$(date +%Y%m%d-%H%M%S).md`

## Template

```markdown
# Validation Report: {{FEATURE}}

**Date**: {{DATE}}
**Engine**: {{ENGINE_NAME}} ({{GO_MODULE}})
**Overall**: {{PASS | FAIL}}

## Pipeline

| Check | Command | Result | Notes |
|-------|---------|--------|-------|
| Formatting | `gofmt -l .` | {{PASS/FAIL}} | {{files needing format or "clean"}} |
| Static analysis | `go vet ./...` | {{PASS/FAIL}} | {{issue count}} |
| Build | `go build ./...` | {{PASS/FAIL}} | |
| Tests (race) | `go test -race ./...` | {{PASS/FAIL}} | {{pass/fail/skip counts}} |
| Lint | `golangci-lint run` | {{PASS/FAIL/SKIPPED}} | {{advisory — not installed?}} |
| Smoke mount | `vault server -dev -dev-plugin-dir` | {{PASS/FAIL/SKIPPED}} | {{advisory — secrets: mount + config + one creds read; database: catalog register + secrets enable database + config write with verify_connection=false}} |

## Design Conformance

| Design section | Result | Mismatches |
|----------------|--------|-----------|
| §3 Paths {{(secrets) / Config fields + credential types (database)}} | {{X/Y match}} | {{list or "none"}} |
| §3 Storage entries {{(secrets) / Statements + method contract (database)}} | {{X/Y match}} | {{list or "none"}} |
| §4 Lifecycle | {{PASS/FAIL}} | {{list or "none"}} |
| §5 Seal-wrap list {{(secrets) / secretValues() list (database)}} | {{PASS/FAIL}} | {{list or "none"}} |
| §6 Checklist | {{X/Y items [x]}} | |

## Test Coverage vs Constitution §6.1

| Scenario | Present |
|----------|---------|
| Config CRUD (read omits secrets) | {{Y/N}} |
| Role/resource CRUD | {{Y/N}} |
| Credential issue | {{Y/N}} |
| Renew | {{Y/N}} |
| Revoke (incl. idempotent) | {{Y/N}} |
| Rotate (incl. WAL) | {{Y/N}} |
| Rotation failure recovery | {{Y/N}} |
| Enterprise modes (on/off) | {{Y/N}} |
| Validation errors | {{Y/N}} |

## Test Coverage vs DB Constitution §6.1 {{(database plugin workflow — replaces the table above)}}

| Scenario | Present |
|----------|---------|
| Initialize: valid config echoes config + supported types | {{Y/N}} |
| Initialize: missing/invalid field named, no client built | {{Y/N}} |
| Initialize: verify_connection on/off | {{Y/N}} |
| Initialize: bad username_template rejected | {{Y/N}} |
| NewUser: happy path (template username, password/roles/expiration reach target) | {{Y/N}} |
| NewUser: statement parse error before target call | {{Y/N}} |
| NewUser: unsupported credential type before target call | {{Y/N}} |
| NewUser: rollback on failure after create | {{Y/N}} |
| NewUser: conflict not rolled back | {{Y/N}} |
| UpdateUser: password change | {{Y/N}} |
| UpdateUser: root self-rotation (config + rawConfig + client; Close + re-Initialize) | {{Y/N}} |
| UpdateUser: expiration applied or loud unsupported error | {{Y/N}} |
| DeleteUser: happy + idempotent | {{Y/N}} |
| Sanitizer redacts password through middleware | {{Y/N}} |
| Not initialized guard | {{Y/N}} |
| Type / Close idempotent | {{Y/N}} |

## Quality Score

{{Quality report table from vault-judge-criteria}}

## Auto-Fixes Applied

{{list or "none"}}

## Remaining Issues

{{numbered list with severity, file:line, remediation — or "none"}}
```

## Rules

1. Replace all `{{PLACEHOLDERS}}` — use "N/A" if data is unavailable
2. Verify no `{{` remains before writing the final file
3. Keep the report under 80 lines — tables over prose
4. Any gofmt/vet/build/test failure forces overall FAIL
5. golangci-lint and the smoke mount are advisory: SKIPPED (tool absent) does
   not force FAIL; findings are listed as issues
6. Constitution §6.1 coverage gaps and D2 < 5.0 force overall FAIL
7. Use exactly ONE coverage table — the secrets-engine one or the database
   one — matching the design's H1; delete the other

## PASS Criteria

- `gofmt -l .` empty; `go vet ./...` clean; `go build ./...` succeeds
- `go test -race ./...` passes with zero failures (skips must cite a reason)
- All design §6 checklist items `[x]`
- Constitution §6.1 coverage table fully present
- Quality score D2 (Security & Compliance) ≥ 5.0
