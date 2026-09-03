#!/usr/bin/env bash
# One-shot skills-vs-baseline A/B for a case: runs the SAME case through both
# the claude-code (plugin) and claude-baseline (stock) adapters with the SAME
# model, then writes a side-by-side comparison. Each underlying run keeps its
# own full run dir (report, artifacts); this just adds a compare dir with the
# diff and pointers — nothing is overwritten.
#
# Usage:
#   compare-case.sh --case <name> [--model M] [--max-turns N] [--keep-workdir]
#                   [--skip-skills | --skip-baseline]
#
#   --skip-skills    reuse your latest existing claude-code run for this case
#                    instead of running it again (saves one metered session).
#   --skip-baseline  run only the skills side (rarely useful; here for symmetry).
#
# Output: runs/<timestamp>-<case>-compare/comparison.md  (+ the two run dirs).
#
# COST WARNING: by default this launches TWO metered `claude -p` workflow
# sessions plus TWO judge sessions. Pin --model so the A/B is fair (the compare
# step warns if the two runs' models differ). Use --model with intent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EVAL_ROOT="${EVAL_ROOT:-$SCRIPT_DIR}"
# shellcheck disable=SC1091
source "$EVAL_ROOT/lib/common.sh"
command -v jq >/dev/null || die "jq is required"

CASE="" MODEL="" MAX_TURNS="" KEEP_WORKDIR=false SKIP_SKILLS=false SKIP_BASELINE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --case) CASE=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --max-turns) MAX_TURNS=$2; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    --skip-skills) SKIP_SKILLS=true; shift ;;
    --skip-baseline) SKIP_BASELINE=true; shift ;;
    *) die "compare-case.sh: unknown arg $1" ;;
  esac
done
[[ -n "$CASE" ]] || die "usage: compare-case.sh --case <name> [--model M] [--max-turns N] [--keep-workdir] [--skip-skills|--skip-baseline]"
[[ -f "$EVAL_ROOT/cases/$CASE/prompt.md" ]] || die "case not found: cases/$CASE/prompt.md"

RUNEVAL="$EVAL_ROOT/run-eval.sh"
COMPARE="$EVAL_ROOT/compare-runs.sh"

# Run one adapter, return its run dir via the RUN_DIR_OUT_FILE handshake.
run_side() { # run_side <adapter> → echoes the run dir
  local adapter=$1 rc=0
  local marker; marker=$(mktemp "${TMPDIR:-/tmp}/eval-rundir.XXXXXX")
  local args=(--case "$CASE" --adapter "$adapter")
  [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
  [[ -n "$MAX_TURNS" ]] && args+=(--max-turns "$MAX_TURNS")
  [[ "$KEEP_WORKDIR" == true ]] && args+=(--keep-workdir)
  log "=== running $adapter for case=$CASE ==="
  RUN_DIR_OUT_FILE="$marker" "$RUNEVAL" "${args[@]}" >&2 || rc=$?
  local dir; dir=$(cat "$marker" 2>/dev/null || true)
  rm -f "$marker"
  [[ -n "$dir" && -d "$dir" ]] || die "$adapter run produced no run dir (rc=$rc)"
  log "$adapter run dir: $dir (rc=$rc)"
  printf '%s' "$dir"
}

# Newest existing run dir for this case on a given adapter (for --skip-skills).
latest_run_for() { # latest_run_for <adapter> → run dir or empty
  local adapter=$1 best=""
  for d in "$EVAL_ROOT"/runs/*-"$CASE"; do
    [[ -f "$d/report.json" ]] || continue
    [[ "$(jq -r '.adapter // ""' "$d/report.json")" == "$adapter" ]] || continue
    best="$d"   # glob is lexicographically sorted; timestamps make newest last
  done
  printf '%s' "$best"
}

SKILLS_DIR="" BASELINE_DIR=""

if [[ "$SKIP_SKILLS" == true ]]; then
  SKILLS_DIR=$(latest_run_for claude-code)
  [[ -n "$SKILLS_DIR" ]] || die "--skip-skills: no existing claude-code run for case=$CASE"
  log "reusing existing skills run: $SKILLS_DIR"
else
  SKILLS_DIR=$(run_side claude-code)
fi

if [[ "$SKIP_BASELINE" == true ]]; then
  BASELINE_DIR=$(latest_run_for claude-baseline)
  [[ -n "$BASELINE_DIR" ]] || die "--skip-baseline: no existing claude-baseline run for case=$CASE"
  log "reusing existing baseline run: $BASELINE_DIR"
else
  BASELINE_DIR=$(run_side claude-baseline)
fi

# ---- comparison output dir ----
CMP="$EVAL_ROOT/runs/$(date -u +%Y%m%dT%H%M%SZ)-$CASE-compare"
mkdir -p "$CMP"
"$COMPARE" "$SKILLS_DIR" "$BASELINE_DIR" --out "$CMP/comparison.md"

log "comparison dir: $CMP"
log "  skills:   $SKILLS_DIR"
log "  baseline: $BASELINE_DIR"
