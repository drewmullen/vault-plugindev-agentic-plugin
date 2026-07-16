---
name: vault-report-template
description: Validation results summary template for Phase 4 output of the secrets engine workflow. Provides the format for reporting gofmt, go vet, go build, go test -race, golangci-lint, dev-server smoke mount, design conformance, and quality score results.
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
| Smoke mount | `vault server -dev -dev-plugin-dir` | {{PASS/FAIL/SKIPPED}} | {{advisory — mount + config + one creds read}} |

## Design Conformance

| Design section | Result | Mismatches |
|----------------|--------|-----------|
| §3 Paths | {{X/Y match}} | {{list or "none"}} |
| §3 Storage entries | {{X/Y match}} | {{list or "none"}} |
| §4 Lifecycle | {{PASS/FAIL}} | {{list or "none"}} |
| §5 Seal-wrap list | {{PASS/FAIL}} | {{list or "none"}} |
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

## PASS Criteria

- `gofmt -l .` empty; `go vet ./...` clean; `go build ./...` succeeds
- `go test -race ./...` passes with zero failures (skips must cite a reason)
- All design §6 checklist items `[x]`
- Constitution §6.1 coverage table fully present
- Quality score D2 (Security & Compliance) ≥ 5.0
