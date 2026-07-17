#!/usr/bin/env bash
# SubagentStop gate: when a subagent finishes inside a generated Vault
# plugin repo, the tree must be gofmt-clean and build/vet-green before the
# agent is allowed to stop. Blocking feeds the failure back to the agent,
# which fixes it in-context — cheaper than the orchestrator re-dispatching
# a fresh instance after the fact.
#
# Deliberately NOT enforced here: `go test` — test expectations are
# phase-dependent (the red baseline REQUIRES failing tests), so tests stay
# an orchestrator-level gate.
#
# Scope guards (this hook ships with the plugin and fires for every
# subagent in every session where the plugin is enabled):
#   - no-op unless the cwd is a Go module depending on hashicorp/vault/sdk
#     (i.e., a generated secrets-engine repo)
#   - no-op when no Go toolchain is on PATH
#   - honors stop_hook_active to avoid blocking loops: if the stop was
#     already blocked once, allow it and let the orchestrator's gates catch
#     what remains
#
# $1 = harness dialect: claude/cursor block on exit 2, copilot on exit 1
set -uo pipefail

DIALECT="${1:-claude}"

payload="$(cat)"

# Loop protection: never block the same stop twice.
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# Scope: generated Vault plugin repos only.
[ -f go.mod ] || exit 0
grep -q 'hashicorp/vault/sdk' go.mod || exit 0
command -v go >/dev/null 2>&1 || exit 0

block() {
  echo "BLOCKED (go gate): $1" >&2
  echo "Fix this, re-run the failing command to confirm, then finish again." >&2
  if [ "$DIALECT" = copilot ]; then exit 1; else exit 2; fi
}

unformatted="$(gofmt -l . 2>/dev/null || true)"
[ -z "$unformatted" ] || block "unformatted files: ${unformatted}. Run: gofmt -w ."

out="$(go build ./... 2>&1)" || block "go build ./... failed:
$(printf '%s' "$out" | head -c 2000)"

out="$(go vet ./... 2>&1)" || block "go vet ./... failed:
$(printf '%s' "$out" | head -c 2000)"

exit 0
