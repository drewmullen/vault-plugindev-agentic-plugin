#!/usr/bin/env bash
# Single-case e2e eval lifecycle for the vault-plugindev workflows:
#   provision throwaway workdir (git init, NO remote → GitHub degradation mode)
#   → adapter runs /vault-secrets-e2e or /vault-db-e2e headlessly (per the
#     case's `workflow` file) → harvest artifacts
#   → deterministic checks → judge (claude-code adapter only)
#   → report.json + report.md under evals/e2e/runs/<timestamp>-<case>/
#
# Usage:
#   run-eval.sh --case <name> --adapter <claude-code|mock>
#               [--model M] [--max-turns N] [--keep-workdir]
#
# Environment:
#   EVAL_TIMEOUT_SECS  adapter timeout (default 5400)
#   JUDGE_MODEL        model for the judge session (claude-code adapter only)
#   MOCK_FAIL=1        make the mock adapter fail like a dead agent
#   MOCK_SLEEP_SECS=N  make the mock adapter take wall time
#
# COST WARNING: --adapter claude-code runs metered `claude -p` sessions (the
# workflow AND the judge). --adapter mock exercises the whole pipeline for $0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EVAL_ROOT="${EVAL_ROOT:-$SCRIPT_DIR}"
# shellcheck disable=SC1091
source "$EVAL_ROOT/lib/common.sh"
export PLUGIN_ROOT

CASE="" ADAPTER="" MODEL="" MAX_TURNS="" KEEP_WORKDIR=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --case) CASE=$2; shift 2 ;;
    --adapter) ADAPTER=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --max-turns) MAX_TURNS=$2; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    *) die "run-eval.sh: unknown arg $1" ;;
  esac
done
[[ -n "$CASE" && -n "$ADAPTER" ]] || die "usage: run-eval.sh --case <name> --adapter <claude-code|mock> [--model M] [--max-turns N] [--keep-workdir]"

CASE_DIR="$EVAL_ROOT/cases/$CASE"
PROMPT_SRC="$CASE_DIR/prompt.md"
ADAPTER_BIN="$EVAL_ROOT/adapters/$ADAPTER.sh"
[[ -f "$PROMPT_SRC" ]] || die "case prompt not found: $PROMPT_SRC"
# Workflow selection: cases/<name>/workflow holds "secrets" (default) or "db".
# Exported so the adapters pick the matching /vault-<workflow>-e2e skill (and
# the mock fabricates a matching design); the judge derives the rubric from
# the design's H1 instead.
EVAL_WORKFLOW=secrets
if [[ -f "$CASE_DIR/workflow" ]]; then
  EVAL_WORKFLOW=$(tr -d '[:space:]' < "$CASE_DIR/workflow")
fi
[[ "$EVAL_WORKFLOW" == "secrets" || "$EVAL_WORKFLOW" == "db" ]] || die "cases/$CASE/workflow must be 'secrets' or 'db' (got '$EVAL_WORKFLOW')"
export EVAL_WORKFLOW
[[ -x "$ADAPTER_BIN" ]] || die "adapter not found/executable: $ADAPTER_BIN"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$CASE"
OUT="$EVAL_ROOT/runs/$RUN_ID"
mkdir -p "$OUT"
cp "$PROMPT_SRC" "$OUT/prompt.md"

# ------------------------------------------------------------- provision ----
# Throwaway workdir: git repo with an initial commit and NO GitHub remote —
# the workflows' documented degradation mode skips issue/PR steps.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/vault-e2e-$CASE.XXXXXX") || die "mktemp failed"
cleanup() {
  if [[ "$KEEP_WORKDIR" == true ]]; then
    log "workdir kept: $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

git -C "$WORKDIR" init -q -b main
# Throwaway repo: pin identity locally and disable commit signing — the
# user's global config may sign via 1Password/SSH, which hangs on an
# interactive approval prompt in unattended runs (observed 2026-07-16).
git -C "$WORKDIR" config user.email eval@local
git -C "$WORKDIR" config user.name eval
git -C "$WORKDIR" config commit.gpgsign false
git -C "$WORKDIR" config tag.gpgsign false
cp "$PROMPT_SRC" "$WORKDIR/eval-prompt.md"   # inside the repo so file-access hooks allow it
git -C "$WORKDIR" add -A
git -C "$WORKDIR" commit -q -m "eval seed"
SEED_COMMIT=$(git -C "$WORKDIR" rev-parse HEAD)

log "case=$CASE adapter=$ADAPTER run=$RUN_ID workdir=$WORKDIR"

# ------------------------------------------------------------------ run -----
TIMEOUT_SECS="${EVAL_TIMEOUT_SECS:-5400}"
adapter_args=(run --prompt-file "$WORKDIR/eval-prompt.md" --workdir "$WORKDIR" \
              --out-dir "$OUT" --timeout-secs "$TIMEOUT_SECS")
[[ -n "$MODEL" ]] && adapter_args+=(--model "$MODEL")
[[ -n "$MAX_TURNS" ]] && adapter_args+=(--max-turns "$MAX_TURNS")

START_EPOCH=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AGENT_RC=0
"$ADAPTER_BIN" "${adapter_args[@]}" || AGENT_RC=$?
RUN_STATUS=$(jq -r '.status // "error"' "$OUT/agent-result.json" 2>/dev/null || echo error)
log "agent run finished: status=$RUN_STATUS rc=$AGENT_RC"

# -------------------------------------------------------------- harvest -----
ART="$OUT/artifacts"
mkdir -p "$ART"
[[ -d "$WORKDIR/specs" ]] && cp -R "$WORKDIR/specs" "$ART/specs"
for f in "$WORKDIR"/*.go "$WORKDIR"/go.mod "$WORKDIR"/go.sum \
         "$WORKDIR"/README.md "$WORKDIR"/Makefile; do
  [[ -f "$f" ]] && cp "$f" "$ART/"
done
git -C "$WORKDIR" log --oneline --stat > "$ART/git-log.txt" 2>/dev/null || true
git -C "$WORKDIR" diff "$SEED_COMMIT" HEAD > "$ART/git-diff.patch" 2>/dev/null || true

# --------------------------------------------------------------- checks -----
# Baseline runs (no plugin) are graded on the code checks only — a stock session
# does not emit the SDD artifacts, so gating it on them would be an unfair FAIL.
CHECK_PROFILE=full
[[ "$ADAPTER" == "claude-baseline" ]] && CHECK_PROFILE=code
"$EVAL_ROOT/checks/deterministic.sh" --workdir "$WORKDIR" --out "$OUT/checks.json" \
  --profile "$CHECK_PROFILE" \
  | tee "$OUT/checks.log" || warn "deterministic checks reported failures"
[[ -s "$OUT/checks.json" ]] || printf '{"checks":{},"pass":false}\n' > "$OUT/checks.json"
CHECKS_PASS=$(jq -r '.pass' "$OUT/checks.json")

# ---------------------------------------------------------------- judge -----
# The judge is measurement infrastructure, not part of the ablation: it runs for
# every real agent adapter (claude-code AND claude-baseline) so both sides get
# scored by the same independent grader. Only the free mock adapter skips it.
if [[ "$ADAPTER" != "mock" ]]; then
  "$EVAL_ROOT/judge/run-judge.sh" --case-dir "$CASE_DIR" --workdir "$WORKDIR" \
    --out-dir "$OUT" --run-status "$RUN_STATUS" || warn "judge had errors"
else
  log "judge skipped (adapter=$ADAPTER)"
  printf 'null\n' > "$OUT/judge-verdict.json"
  jq -n '{judge_error: null, skipped: true, cost_usd: null}' > "$OUT/judge-result.json"
fi

# --------------------------------------------------------------- report -----
END_EPOCH=$(date +%s)
ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WALL=$(( END_EPOCH - START_EPOCH ))
MIN_SCORE="${JUDGE_MIN_SCORE:-7.0}"

ensure_json() { [[ -s "$1" ]] && jq -e . "$1" >/dev/null 2>&1 || printf '%s\n' "$2" > "$1"; }
ensure_json "$OUT/agent-result.json" '{"adapter":null,"model":null,"cost_usd":null,"num_turns":null,"session_id":null,"exit_code":null,"status":"error"}'
ensure_json "$OUT/agent-envelope.json" 'null'
ensure_json "$OUT/judge-verdict.json" 'null'
ensure_json "$OUT/judge-result.json" '{"judge_error":"judge produced no result","skipped":false,"cost_usd":null}'

jq -n \
  --arg run_id "$RUN_ID" --arg case_id "$CASE" --arg adapter "$ADAPTER" \
  --arg status "$RUN_STATUS" \
  --arg started "$STARTED_AT" --arg ended "$ENDED_AT" \
  --argjson wall "$WALL" \
  --argjson min "$MIN_SCORE" \
  --slurpfile agent "$OUT/agent-result.json" \
  --slurpfile envelope "$OUT/agent-envelope.json" \
  --slurpfile checks "$OUT/checks.json" \
  --slurpfile verdict "$OUT/judge-verdict.json" \
  --slurpfile jresult "$OUT/judge-result.json" \
  '
  ($verdict[0]) as $j |
  ($jresult[0].skipped // false) as $judge_skipped |
  ($j != null and ($j.overall // 0) >= $min and (($j.security_override_triggered // false) | not)) as $judge_ok |
  {
    schema_version: 1,
    run_id: $run_id, case: $case_id, adapter: $adapter,
    status: $status,
    started_at: $started, ended_at: $ended, wall_time_s: $wall,
    agent: {
      adapter: $agent[0].adapter, model: $agent[0].model,
      cost_usd: $agent[0].cost_usd, num_turns: $agent[0].num_turns,
      session_id: $agent[0].session_id, exit_code: $agent[0].exit_code,
      model_usage: (try $envelope[0].modelUsage catch null)
    },
    deterministic: {pass: $checks[0].pass, checks: $checks[0].checks},
    judge: (if $j == null then null else {
      overall: $j.overall, production_ready: $j.production_ready,
      security_override: ($j.security_override_triggered // false),
      dimensions: ($j.dimensions | with_entries(.value = (.value | if type == "object" then .score else . end))),
      assertions_passed: ([$j.assertions[] | select(.pass)] | length),
      assertions_total: ($j.assertions | length),
      judge_cost_usd: $jresult[0].cost_usd
    } end),
    judge_skipped: $judge_skipped,
    judge_error: $jresult[0].judge_error,
    grade: (if $status != "passed" then "fail"
            elif ($checks[0].pass | not) then "fail"
            elif $judge_skipped then (if $adapter == "mock" then "pass" else "fail" end)
            elif $judge_ok then "pass"
            else "fail" end)
  }' > "$OUT/report.json"

GRADE=$(jq -r '.grade' "$OUT/report.json")

{
  echo "# E2E Eval Report — $CASE"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Run | \`$RUN_ID\` |"
  echo "| Adapter | $ADAPTER |"
  echo "| Grade | **$(tr '[:lower:]' '[:upper:]' <<<"$GRADE")** |"
  echo "| Agent status | $RUN_STATUS |"
  echo "| Wall time | ${WALL}s |"
  echo "| Agent cost (USD) | $(jq -r '.agent.cost_usd // "n/a"' "$OUT/report.json") |"
  echo "| Turns | $(jq -r '.agent.num_turns // "n/a"' "$OUT/report.json") |"
  echo "| Model | $(jq -r '.agent.model // "n/a"' "$OUT/report.json") |"
  echo
  if jq -e '.agent.model_usage | objects | length > 0' "$OUT/report.json" >/dev/null 2>&1; then
    echo "## Tokens by model"
    echo
    echo "| Model | Output | Fresh input | Cache reads | Cache writes | Cost (USD) |"
    echo "|---|---|---|---|---|---|"
    jq -r '.agent.model_usage | to_entries[] |
      "| \(.key) | \(.value.outputTokens // 0) | \(.value.inputTokens // 0) | \(.value.cacheReadInputTokens // 0) | \(.value.cacheCreationInputTokens // 0) | \(.value.costUSD // 0 | (.*100 | round) / 100) |"' \
      "$OUT/report.json"
    echo
  fi
  echo "## Deterministic checks — $([[ "$CHECKS_PASS" == "true" ]] && echo PASS || echo FAIL)"
  echo
  echo "| Check | Result | Detail |"
  echo "|---|---|---|"
  jq -r '.checks | to_entries[] |
    "| \(.key) | \(if .value.pass then "PASS" elif .value.skipped then "SKIP" else "FAIL" end) | \(.value.detail // "") |"' \
    "$OUT/checks.json"
  echo
  echo "## Judge"
  echo
  if [[ "$(jq -r '.judge_skipped' "$OUT/report.json")" == "true" ]]; then
    echo "Skipped (adapter=$ADAPTER)."
  elif [[ "$(jq -r '.judge' "$OUT/report.json")" == "null" ]]; then
    echo "No verdict — judge_error: $(jq -r '.judge_error // "unknown"' "$OUT/report.json")"
  else
    echo "Overall: **$(jq -r '.judge.overall' "$OUT/report.json")** (min $MIN_SCORE)" \
         "— production ready: $(jq -r '.judge.production_ready' "$OUT/report.json")," \
         "security override: $(jq -r '.judge.security_override' "$OUT/report.json")"
    echo
    echo "| Dimension | Score |"
    echo "|---|---|"
    jq -r '.judge.dimensions | to_entries[] | "| \(.key) | \(.value) |"' "$OUT/report.json"
    echo
    echo "Assertions: $(jq -r '.judge.assertions_passed' "$OUT/report.json")/$(jq -r '.judge.assertions_total' "$OUT/report.json") passed;" \
         "judge cost: \$$(jq -r '.judge.judge_cost_usd // "n/a"' "$OUT/report.json")"
  fi
  echo
  echo "Artifacts: \`$OUT/artifacts/\` (specs, Go sources, git log/diff)."
} > "$OUT/report.md"

log "report: $OUT/report.md"
log "case $CASE: status=$RUN_STATUS checks_pass=$CHECKS_PASS grade=$GRADE wall=${WALL}s"

# Machine-readable handshake for compare-case.sh: when RUN_DIR_OUT_FILE is set,
# record this run's output directory there (stdout carries check output, so a
# dedicated file is the reliable channel).
[[ -n "${RUN_DIR_OUT_FILE:-}" ]] && printf '%s\n' "$OUT" > "$RUN_DIR_OUT_FILE"

[[ "$GRADE" == "pass" ]]
