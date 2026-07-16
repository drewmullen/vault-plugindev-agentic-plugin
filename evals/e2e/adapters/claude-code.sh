#!/usr/bin/env bash
# Runtime adapter: Claude Code headless. The ONLY file in the harness that
# invokes `claude`. Implements the adapter contract:
#
#   claude-code.sh run --prompt-file F --workdir D --out-dir O --timeout-secs N
#                      [--model M] [--max-turns K]
#
# Plugin loading: the plugin repo root is passed to `claude --plugin-dir`, so
# the run gets the vault-plugindev skills/agents/hooks for this session only,
# and `${CLAUDE_PLUGIN_ROOT}` inside the skills resolves to the plugin root —
# no copying into the workdir needed.
#
# The prompt sent is `/vault-secrets-e2e <prompt-file>` — the non-interactive
# harness skill reads the case prompt (engine request + Test Defaults) itself.
#
# Produces in O:
#   agent-envelope.json — raw `--output-format json` result envelope
#   agent-result.json   — normalized result, written even on timeout/crash
#
# COST WARNING: every invocation is a metered `claude -p` run. Never execute
# this adapter casually; syntax-check with `bash -n` instead.
set -uo pipefail
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ADAPTER_DIR/../lib/common.sh"

[[ "${1:-}" == "run" ]] || die "usage: claude-code.sh run --prompt-file F --workdir D --out-dir O --timeout-secs N"
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
    *) die "claude-code.sh: unknown arg $1" ;;
  esac
done
[[ -f "$PROMPT_FILE" && -d "$WORKDIR" && -n "$OUT" ]] || die "claude-code.sh: missing required args"
mkdir -p "$OUT"

command -v claude >/dev/null || die "claude CLI not found on PATH"

# Refer to the prompt file relative to the workdir when it lives inside it
# (the runner copies it there so the out-of-tree file-access hook allows it).
prompt_ref="$PROMPT_FILE"
case "$PROMPT_FILE" in
  "$WORKDIR"/*) prompt_ref="${PROMPT_FILE#"$WORKDIR"/}" ;;
esac

args=(-p "/vault-secrets-e2e $prompt_ref"
  --output-format json
  --plugin-dir "$PLUGIN_ROOT"
  --dangerously-skip-permissions)
[[ -n "$MODEL" ]] && args+=(--model "$MODEL")
[[ -n "$MAX_TURNS" ]] && args+=(--max-turns "$MAX_TURNS")

start_ts=$(date +%s)
set +e
(
  cd "$WORKDIR" || exit 97
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

# The json envelope carries cost/turn/session facts. Tolerate a missing or
# truncated envelope (timeout/crash) — the result is still normalized.
envelope=$(jq -c '.' "$OUT/agent-envelope.json" 2>/dev/null || echo '{}')
[[ -n "$envelope" ]] || envelope='{}'

# Exit 0 is not enough: the envelope can carry is_error=true (e.g. max-turns
# hit), and an empty envelope means the stream was truncated — both failures.
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
  --arg adapter "claude-code" \
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

log "claude-code adapter done: status=$status exit=$exit_code cost=$(jq -r '.cost_usd // "n/a"' "$OUT/agent-result.json")"
[[ "$status" == "passed" ]]
