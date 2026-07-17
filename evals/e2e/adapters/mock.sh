#!/usr/bin/env bash
# Runtime adapter: mock. Fabricates what a successful /vault-secrets-e2e run
# leaves behind, for $0, so the whole pipeline (runner → harvest → checks →
# judge-skip → report) can be exercised without an agent.
#
# Same contract as claude-code.sh. Honors:
#   MOCK_FAIL=1       — exit nonzero like an agent failure (no artifacts)
#   MOCK_SLEEP_SECS=N — simulate wall time (useful for interrupt testing)
set -uo pipefail
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ADAPTER_DIR/../lib/common.sh"

[[ "${1:-}" == "run" ]] || die "usage: mock.sh run --prompt-file F --workdir D --out-dir O ..."
shift

PROMPT_FILE="" WORKDIR="" OUT="" TIMEOUT_SECS=5400 MODEL="" MAX_TURNS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt-file) PROMPT_FILE=$2; shift 2 ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --out-dir) OUT=$2; shift 2 ;;
    --timeout-secs) TIMEOUT_SECS=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --max-turns) MAX_TURNS=$2; shift 2 ;;
    *) die "mock.sh: unknown arg $1" ;;
  esac
done
[[ -f "$PROMPT_FILE" && -d "$WORKDIR" && -n "$OUT" ]] || die "mock.sh: missing required args"
mkdir -p "$OUT"

sleep "${MOCK_SLEEP_SECS:-0}"

write_result() { # write_result <exit_code> <status>
  jq -n \
    --argjson exit_code "$1" \
    --arg status "$2" \
    --arg model "${MODEL:-mock}" \
    '{
      schema_version: 1, adapter: "mock", exit_code: $exit_code, status: $status,
      cost_usd: 0.0, duration_ms: 31000, wall_time_s: 31, num_turns: 42,
      session_id: "mock-session", model: $model, is_error: ($status != "passed"),
      result_text: (if $status == "passed"
        then "E2E secrets engine test complete. Status: PASSED."
        else "mock agent failure (MOCK_FAIL=1)" end)
    }' > "$OUT/agent-result.json"
}

if [[ "${MOCK_FAIL:-0}" == "1" ]]; then
  write_result 1 error
  log "mock adapter done: status=error (MOCK_FAIL=1)"
  exit 1
fi

# ---- fabricate the artifact tree a real workflow run would leave behind ----
FEATURE="001-mock"
SPEC="$WORKDIR/specs/$FEATURE"
STAMP="$(date +%Y%m%d)-0000"
mkdir -p "$SPEC/reports"

cat > "$SPEC/design.md" <<'EOF'
# Secrets Engine Design: mock-engine

**Branch**: 001-mock
**Status**: Approved
**Go Module**: example.com/mock-engine

## 1. Purpose & Requirements

Mock secrets engine design fabricated by the eval mock adapter. Manages
nothing; exists so the deterministic checks have a complete artifact to gate.

**Credential model**: dynamic ephemeral — fabricated.

## 2. External API Integration

Mock target API. Token auth; create/revoke endpoints; 404 on revoke treated
as success.

## 3. Backend Interface Contract

Flat paths: `config`, `roles/<name>`, `creds/<name>`. Storage entries carry
a Version field.

## 4. Credential Lifecycle

Issue via `creds/<name>` with a lease; idempotent revoke; manual rotation
with WAL-before-external-mutation ordering.

### Enterprise-Dependent Features

| Feature | Depends on | How disabled | Disabled behavior on OSS Vault |
|---------|-----------|--------------|--------------------------------|
| Automated rotation | Rotation Manager (Enterprise) | `disable_automated_rotation` (default: true) | Manual rotation endpoints work identically |

## 5. Security Controls

- Secret material map: `config` storage entry only
- Seal-wrap list: `config`
- No secret value is logged at any level

## 6. Implementation Checklist

- [x] **A: Client & config** — files: client.go, path_config.go; depends-on: —; skills: vault-plugin-config-client
- [x] **B: Roles** — files: path_roles.go; depends-on: A (client seam); skills: vault-plugin-dynamic-roles
- [x] **C: Credential issuance** — files: path_creds.go, secret_token.go; depends-on: A, B; skills: vault-plugin-dynamic-creds
- [x] **D: Rotation & WAL** — files: path_rotate.go, wal.go; depends-on: C; skills: vault-plugin-config-client

## 7. Open Questions

None — all resolved.
EOF

cat > "$SPEC/clarifications.md" <<'EOF'
# Clarifications (mock)

- Credential model: dynamic ephemeral
- Security defaults: proposed defaults accepted (TTL 1h / max 24h)
- Go module org: example.com/mock-engine
- Integration environment: fakes only
EOF

cat > "$SPEC/research-target-api.md" <<'EOF'
# Research: target API (mock)

Findings: token auth, create/revoke endpoints, 429 throttling with
Retry-After. Fabricated by the mock adapter.

### Sources

- https://example.com/mock-api-docs
- Public precedent: vault-plugin-secrets-openldap layout (allowed here —
  citations may appear on/after the Sources line)
EOF

cat > "$SPEC/research-sdk-patterns.md" <<'EOF'
# Research: SDK patterns (mock)

Findings: framework.Backend with path families, lease-backed secrets,
WAL-protected rotation. Fabricated by the mock adapter.

### Sources

- https://pkg.go.dev/github.com/hashicorp/vault/sdk/framework
EOF

cat > "$SPEC/reports/review_$STAMP.md" <<'EOF'
# In-Loop Review Report (mock)

No defects found. Fabricated by the mock adapter.
EOF

cat > "$SPEC/reports/validation_$STAMP.md" <<'EOF'
# Validation Report (mock)

## Quality Score: 001-mock

### Overall: 8.4/10.0 — Excellent

Fabricated by the mock adapter.
EOF

# ---- trivially buildable Go module at the workdir root (no external deps) ----
cat > "$WORKDIR/go.mod" <<'EOF'
module example.com/mock-engine

go 1.24
EOF

cat > "$WORKDIR/backend.go" <<'EOF'
// Package mockengine is a trivially buildable stand-in generated by the e2e
// eval mock adapter. It exists only so gofmt/build/vet/test gates run.
package mockengine

// EngineName is the mock engine's registered name.
const EngineName = "mock-engine"

// PathFamilies lists the mock engine's flat path families.
func PathFamilies() []string {
	return []string{"config", "roles/", "creds/"}
}
EOF

cat > "$WORKDIR/backend_test.go" <<'EOF'
package mockengine

import "testing"

func TestPathFamilies(t *testing.T) {
	got := PathFamilies()
	if len(got) != 3 {
		t.Fatalf("expected 3 path families, got %d", len(got))
	}
	if got[0] != "config" {
		t.Fatalf("expected first path family to be config, got %q", got[0])
	}
}
EOF

# Simulate the workflow's checkpoint commits so git-log harvest has content.
git -C "$WORKDIR" add -A 2>/dev/null || true
git -C "$WORKDIR" -c user.email=eval@local -c user.name=eval \
  commit -q -m "feat: mock plan+implement checkpoint" 2>/dev/null || true

write_result 0 passed
log "mock adapter done: status=passed"
