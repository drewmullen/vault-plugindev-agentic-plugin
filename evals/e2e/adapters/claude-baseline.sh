#!/usr/bin/env bash
# Runtime adapter: Claude Code headless BASELINE (no plugin). Runs the same case
# requirements through a stock `claude -p` session with NO --plugin-dir, so the
# session gets none of the vault-plugindev skills, subagents, or hooks. The only
# difference from claude-code.sh is the missing plugin — this is the ablation
# baseline that isolates the plugin's lift.
#
# Same adapter contract as claude-code.sh:
#   claude-baseline.sh run --prompt-file F --workdir D --out-dir O --timeout-secs N
#                          [--model M] [--max-turns K]
#
# Prompt: the case file is written for the /vault-secrets-e2e skill, which does
# not exist here. This adapter DERIVES a vanilla build request from it — the
# `## Engine Request` through (but not including) `## Workflow Instructions`
# span (Engine Request + any Target API spec + Test Defaults), under a neutral
# preamble that pins the same repo layout the workflow uses so harvest, the
# deterministic code checks, and the judge all work unchanged.
#
# Produces in O:
#   agent-envelope.json — raw `--output-format json` result envelope
#   agent-result.json   — normalized result (adapter="claude-baseline")
#
# COST WARNING: every invocation is a metered `claude -p` run, same as
# claude-code.sh. Syntax-check with `bash -n` instead of running casually.
set -uo pipefail
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ADAPTER_DIR/../lib/common.sh"

[[ "${1:-}" == "run" ]] || die "usage: claude-baseline.sh run --prompt-file F --workdir D --out-dir O --timeout-secs N"
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
    *) die "claude-baseline.sh: unknown arg $1" ;;
  esac
done
[[ -f "$PROMPT_FILE" && -d "$WORKDIR" && -n "$OUT" ]] || die "claude-baseline.sh: missing required args"
mkdir -p "$OUT"

command -v claude >/dev/null || die "claude CLI not found on PATH"

# ---- derive a vanilla build prompt from the skill-oriented case file ----
# Keep the requirements span; drop the title, the "don't prompt me" preamble,
# the skill-invocation line, and the "## Workflow Instructions" section (which
# references the orchestrator skills that do not exist in a baseline run).
requirements=$(awk '
  /^## Engine Request/        { keep = 1 }
  /^## Workflow Instructions/ { keep = 0 }
  keep                        { print }
' "$PROMPT_FILE")
[[ -n "$requirements" ]] || die "claude-baseline.sh: no '## Engine Request' section in $PROMPT_FILE"

PROMPT_TEXT=$(cat <<EOF
You are building a production-grade HashiCorp Vault secrets engine plugin in Go.

Work directly in the current working directory, which is a fresh git repository.
Put the Go source files and \`go.mod\` at the REPOSITORY ROOT — do not create a
nested module subdirectory. Implement the engine described below and follow the
Test Defaults verbatim for every decision they cover.

This is an automated, non-interactive run: do not ask any questions. Make and
briefly record best-practice decisions yourself, and resolve any problems without
prompting. Write the plugin code and its Go tests; ensure \`go build ./...\` and
\`go test ./...\` pass and the tree is gofmt-clean; then commit your work.

---

$requirements
EOF
)

args=(-p "$PROMPT_TEXT"
  --output-format json
  --dangerously-skip-permissions)
[[ -n "$MODEL" ]] && args+=(--model "$MODEL")
[[ -n "$MAX_TURNS" ]] && args+=(--max-turns "$MAX_TURNS")

start_ts=$(date +%s)
set +e
(
  cd "$WORKDIR" || exit 97
  # NB: no --plugin-dir and no VAULT_E2E_EVAL — the plugin's eval-mode Stop gate
  # does not exist in a baseline session, so nothing arms it.
  run_with_timeout "$TIMEOUT_SECS" claude "${args[@]}"
) > "$OUT/agent-envelope.json" 2> "$OUT/agent-stderr.log"
exit_code=$?
set -e
end_ts=$(date +%s)

status="passed"
if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
  status="timeout"   # GNU timeout TERM / KILL; watchdog fallback reports 143 (error)
elif [[ $exit_code -ne 0 ]]; then
  status="error"
fi

envelope=$(jq -c '.' "$OUT/agent-envelope.json" 2>/dev/null || echo '{}')
[[ -n "$envelope" ]] || envelope='{}'

if [[ "$status" == "passed" ]]; then
  if [[ "$envelope" == '{}' ]]; then
    status="error"
    warn "claude exited 0 but produced no result envelope — marking error"
  elif [[ "$(jq -r '.is_error // false' <<<"$envelope")" == "true" ]]; then
    status="error"
    warn "result envelope reports is_error=true — marking error"
  fi
fi

jq -n \
  --arg adapter "claude-baseline" \
  --argjson exit_code "$exit_code" \
  --arg status "$status" \
  --arg model "$MODEL" \
  --argjson wall "$(( end_ts - start_ts ))" \
  --argjson ev "$envelope" \
  '{
    schema_version: 1,
    adapter: $adapter,
    exit_code: $exit_code,
    status: $status,
    cost_usd: ($ev.total_cost_usd // null),
    duration_ms: ($ev.duration_ms // ($wall * 1000)),
    wall_time_s: $wall,
    num_turns: ($ev.num_turns // null),
    session_id: ($ev.session_id // null),
    model: (if $model == "" then ($ev.model // null) else $model end),
    is_error: ($ev.is_error // ($status != "passed")),
    result_text: ($ev.result // null)
  }' > "$OUT/agent-result.json"

log "claude-baseline adapter done: status=$status exit=$exit_code cost=$(jq -r '.cost_usd // "n/a"' "$OUT/agent-result.json")"
[[ "$status" == "passed" ]]
