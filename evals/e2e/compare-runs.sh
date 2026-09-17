#!/usr/bin/env bash
# Diff two completed e2e run directories side by side — built for the
# skills-vs-baseline ablation (claude-code vs claude-baseline) but works on any
# two runs. Reads each run's report.json and emits one markdown table: grade,
# judge overall + the 6 dimensions, the code gates (gofmt/build/vet/test), wall
# time, cost, and turns, with a Δ column on the numeric rows.
#
# Usage:
#   compare-runs.sh <run-dir-a> <run-dir-b> [--out <file.md>]
#
# The runs are auto-labeled by adapter (claude-code → "skills",
# claude-baseline → "baseline"); column A is whichever dir you pass first.
# WARNS (does not abort) if the two runs are different cases or different
# models — either makes the delta mean something other than "the plugin".
#
# No API cost: this only reads report.json files.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
command -v jq >/dev/null || die "jq is required"

DIR_A="" DIR_B="" OUT_FILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --out) OUT_FILE=$2; shift 2 ;;
    -*) die "compare-runs.sh: unknown flag $1" ;;
    *) if [[ -z "$DIR_A" ]]; then DIR_A=$1; elif [[ -z "$DIR_B" ]]; then DIR_B=$1; else die "compare-runs.sh: too many args"; fi; shift ;;
  esac
done
[[ -n "$DIR_A" && -n "$DIR_B" ]] || die "usage: compare-runs.sh <run-dir-a> <run-dir-b> [--out <file.md>]"
RA="$DIR_A/report.json"; RB="$DIR_B/report.json"
[[ -f "$RA" ]] || die "no report.json in $DIR_A"
[[ -f "$RB" ]] || die "no report.json in $DIR_B"

# ---- pull the facts we compare ----
q() { jq -r "$1 // \"n/a\"" "$2"; }               # scalar or "n/a"
qmoney() { jq -r "if ($1) == null then \"n/a\" else (($1) * 100 | round) / 100 end" "$2"; }  # 2dp USD
qd() { jq -r ".judge // {} | ($1) // \"n/a\"" "$2"; }  # judge subfield or "n/a"
chk() { # chk <check> <report> → PASS|FAIL|SKIP|n/a
  jq -r --arg c "$1" '.deterministic.checks[$c] // {} |
    if .pass then "PASS" elif .skipped then "SKIP" elif has("pass") then "FAIL" else "n/a" end' "$2"
}

CASE_A=$(q '.case' "$RA");     CASE_B=$(q '.case' "$RB")
ADAPT_A=$(q '.adapter' "$RA"); ADAPT_B=$(q '.adapter' "$RB")
MODEL_A=$(q '.agent.model' "$RA"); MODEL_B=$(q '.agent.model' "$RB")

label() { case $1 in claude-code) echo "skills";; claude-baseline) echo "baseline";; *) echo "$1";; esac; }
LAB_A="$(label "$ADAPT_A") ($ADAPT_A)"; LAB_B="$(label "$ADAPT_B") ($ADAPT_B)"

# ---- fairness guards (warn, never abort) ----
warnings=()
if [[ "$CASE_A" != "$CASE_B" ]]; then
  warnings+=("CASE MISMATCH: '$CASE_A' vs '$CASE_B' — a cross-case delta is meaningless.")
fi
if [[ "$MODEL_A" != "$MODEL_B" ]]; then
  warnings+=("MODEL MISMATCH: '$MODEL_A' vs '$MODEL_B' — the delta then reflects the model, not the plugin. Re-run with a matched --model.")
fi
for w in "${warnings[@]:-}"; do [[ -n "$w" ]] && warn "$w"; done

# ---- numeric delta helper (B - A), one decimal; blank if either is n/a ----
delta() { # delta <a> <b>
  [[ "$1" == "n/a" || "$2" == "n/a" ]] && { echo ""; return; }
  awk -v a="$1" -v b="$2" 'BEGIN{ d=b-a; printf (d>=0?"+%.2f":"%.2f"), d }' 2>/dev/null || echo ""
}

row() { # row <label> <a> <b> [numeric]
  local d=""
  [[ "${4:-}" == num ]] && d=$(delta "$2" "$3")
  printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$d"
}

emit() {
  echo "# E2E Comparison — $CASE_A"
  echo
  if [[ ${#warnings[@]} -gt 0 && -n "${warnings[0]:-}" ]]; then
    echo "> ⚠️ **Not an apples-to-apples comparison:**"
    for w in "${warnings[@]}"; do [[ -n "$w" ]] && echo "> - $w"; done
    echo
  fi
  echo "| | A: $LAB_A | B: $LAB_B |"
  echo "|---|---|---|"
  echo "| Run dir | \`$(basename "$DIR_A")\` | \`$(basename "$DIR_B")\` |"
  echo "| Case | $CASE_A | $CASE_B |"
  echo "| Model | $MODEL_A | $MODEL_B |"
  echo "| Grade | **$(q '.grade' "$RA")** | **$(q '.grade' "$RB")** |"
  echo
  echo "## Judge (B − A)"
  echo
  echo "| Metric | A ($(label "$ADAPT_A")) | B ($(label "$ADAPT_B")) | Δ |"
  echo "|---|---|---|---|"
  row "Overall"          "$(qd '.overall' "$RA")"          "$(qd '.overall' "$RB")"          num
  row "D1 Backend/Path"  "$(qd '.dimensions.d1' "$RA")"    "$(qd '.dimensions.d1' "$RB")"    num
  row "D2 Security"      "$(qd '.dimensions.d2' "$RA")"    "$(qd '.dimensions.d2' "$RB")"    num
  row "D3 Code Quality"  "$(qd '.dimensions.d3' "$RA")"    "$(qd '.dimensions.d3' "$RB")"    num
  row "D4 Cred Lifecycle" "$(qd '.dimensions.d4' "$RA")"   "$(qd '.dimensions.d4' "$RB")"    num
  row "D5 Testing"       "$(qd '.dimensions.d5' "$RA")"    "$(qd '.dimensions.d5' "$RB")"    num
  row "D6 Constitution"  "$(qd '.dimensions.d6' "$RA")"    "$(qd '.dimensions.d6' "$RB")"    num
  row "Production ready" "$(qd '.production_ready' "$RA")"  "$(qd '.production_ready' "$RB")"
  row "Security override" "$(qd '.security_override' "$RA")" "$(qd '.security_override' "$RB")"
  echo
  echo "## Code gates"
  echo
  echo "| Check | A ($(label "$ADAPT_A")) | B ($(label "$ADAPT_B")) |"
  echo "|---|---|---|"
  for c in gofmt go_build go_vet go_test; do
    printf '| %s | %s | %s |\n' "$c" "$(chk "$c" "$RA")" "$(chk "$c" "$RB")"
  done
  echo
  echo "## Cost & effort"
  echo
  echo "| Metric | A ($(label "$ADAPT_A")) | B ($(label "$ADAPT_B")) | Δ |"
  echo "|---|---|---|---|"
  row "Wall time (s)"   "$(q '.wall_time_s' "$RA")"    "$(q '.wall_time_s' "$RB")"    num
  row "Agent cost (USD)" "$(qmoney '.agent.cost_usd' "$RA")" "$(qmoney '.agent.cost_usd' "$RB")" num
  row "Turns"           "$(q '.agent.num_turns' "$RA")" "$(q '.agent.num_turns' "$RB")" num
  echo
  echo "_A = \`$DIR_A\`_  "
  echo "_B = \`$DIR_B\`_"
}

if [[ -n "$OUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUT_FILE")"
  emit | tee "$OUT_FILE"
  log "comparison written: $OUT_FILE"
else
  emit
fi
