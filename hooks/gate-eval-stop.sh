#!/usr/bin/env bash
# Stop gate, eval mode only: the session may not stop while the e2e workflow
# is artifact-incomplete. Guards against the observed $21 failure mode where
# a headless session ended early (paused a background agent and asked a
# question no user could answer).
#
# Scope: fires ONLY when VAULT_E2E_EVAL=1 (exported by the claude-code eval
# adapter). Interactive sessions are never affected.
#
# Completeness rule (artifact-based, mirrors the vault-secrets-e2e skill's
# completion contract): once any specs/*/design.md exists, the session may
# stop only when a specs/*/reports/validation_*.md also exists.
#
# Honors stop_hook_active: if this stop was already blocked once, allow it —
# the deterministic checks grade whatever state remains.
#
# $1 = harness dialect: claude/cursor block on exit 2, copilot on exit 1
set -uo pipefail

DIALECT="${1:-claude}"

[ "${VAULT_E2E_EVAL:-0}" = "1" ] || exit 0

payload="$(cat)"
if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

design_exists=false
for d in specs/*/design.md; do
  [ -f "$d" ] && design_exists=true && break
done
$design_exists || exit 0

for v in specs/*/reports/validation_*.md; do
  [ -f "$v" ] && exit 0
done

echo "EVAL GATE: the e2e workflow is incomplete — a design.md exists but no specs/*/reports/validation_*.md. There is no user to hand off to in this headless run. Continue the workflow: finish remaining implement waves, reconciliation, the in-loop review, and the validator, then end with the single status line." >&2
if [ "$DIALECT" = copilot ]; then exit 1; else exit 2; fi
