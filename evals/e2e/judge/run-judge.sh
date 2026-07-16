#!/usr/bin/env bash
# Launch the independent judge in a FRESH headless session (zero shared context
# with the graded run), extract and validate its JSON verdict.
#
# Usage: run-judge.sh --case-dir <dir> --workdir <dir> --out-dir <dir>
#                     [--run-status passed|timeout|error]
#
# The judge follows the vault-e2e-judge agent contract (.claude/agents/
# vault-e2e-judge.md): read-only, scores against the vault-judge-criteria
# rubric (loaded via --plugin-dir) plus per-case assertions from
# <case-dir>/assertions.md when present.
#
# Writes: <out-dir>/judge-verdict.json  (null on failure)
#         <out-dir>/judge-result.json   (judge session cost/duration facts)
#
# COST WARNING: this is a metered `claude -p` session. Set JUDGE_MODEL in the
# environment to keep grading on a cheap model.
set -uo pipefail
JUDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$JUDGE_DIR/../lib/common.sh"

CASE_DIR="" WORKDIR="" OUT="" RUN_STATUS="passed"
while [[ $# -gt 0 ]]; do
  case $1 in
    --case-dir) CASE_DIR=$2; shift 2 ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --out-dir) OUT=$2; shift 2 ;;
    --run-status) RUN_STATUS=$2; shift 2 ;;
    *) die "run-judge.sh: unknown arg $1" ;;
  esac
done
[[ -d "$CASE_DIR" && -d "$WORKDIR" && -n "$OUT" ]] || die "run-judge.sh: --case-dir, --workdir, --out-dir required"
mkdir -p "$OUT"

fail_soft() {
  warn "judge failed: $1"
  printf 'null\n' > "$OUT/judge-verdict.json"
  jq -n --arg err "$1" '{judge_error: $err, skipped: false, cost_usd: null}' > "$OUT/judge-result.json"
  exit 0   # a broken judge never fails the pipeline; the report records judge_error
}

command -v claude >/dev/null || fail_soft "claude CLI not found"

assertions="(none — score the rubric only)"
if [[ -f "$CASE_DIR/assertions.md" ]]; then
  assertions=$(cat "$CASE_DIR/assertions.md")
fi
run_incomplete=false
[[ "$RUN_STATUS" == "timeout" || "$RUN_STATUS" == "error" ]] && run_incomplete=true

cat > "$OUT/judge-prompt.md" <<EOF
You are the **vault-e2e-judge** agent for this session: an independent,
read-only grader of a completed /vault-secrets-e2e workflow run. You share no
context with the run. Follow the agent contract exactly:

1. Read-only. Never write, edit, or mutate anything. Bash only for
   \`git diff\` / \`git log\` inspection.
2. Do NOT read the workflow's own opinions: skip
   \`specs/*/reports/validation_*.md\` and \`specs/*/reports/review_*.md\`
   entirely — your score must be independent.
3. Evidence or it didn't happen: every dimension score and assertion verdict
   cites file:line evidence.
4. Your final message is exactly ONE fenced \`\`\`json block. No prose around it.

## Inputs

- Working directory: the generated plugin repo (design docs under \`specs/\`,
  Go code at the root).
- Deterministic gate outcomes: $OUT/checks.json (read for facts, do not re-litigate)
- Run status: $RUN_STATUS (run_incomplete: $run_incomplete — if true, grade
  the partial artifacts and say so in \`summary\`)

## Per-case assertions

$assertions

## Method

1. Load the \`vault-judge-criteria\` skill. Use its 6 secrets-engine
   dimensions, weights, scoring formula, and the Security (D2) < 5.0
   "Not Production Ready" override.
2. Read \`specs/*/design.md\`, then the Go code, then \`git log\`. Cross-check
   the design's §3/§4 scenario tables and §6 checklist against what was built.
3. Evaluate each per-case assertion strictly: \`pass\` only with cited evidence.
4. Score all 6 dimensions with file:line evidence, compute the weighted
   overall score (one decimal), and classify top issues by P0-P3 severity.

## Output schema (exactly this shape, one fenced \`\`\`json block)

\`\`\`json
{
  "rubric": "vault-secrets-engine",
  "dimensions": {
    "d1": {"name": "Backend & Path Design", "score": 8.0, "issues": ["..."]},
    "d2": {"name": "Security & Compliance", "score": 7.5, "issues": []},
    "d3": {"name": "Code Quality", "score": 8.0, "issues": []},
    "d4": {"name": "Credential Lifecycle", "score": 8.0, "issues": []},
    "d5": {"name": "Testing", "score": 8.5, "issues": []},
    "d6": {"name": "Constitution Alignment", "score": 7.5, "issues": []}
  },
  "overall": 7.85,
  "production_ready": true,
  "security_override_triggered": false,
  "assertions": [
    {"text": "...", "pass": true, "evidence": "path_creds.go:12-18"}
  ],
  "top_issues": [
    {"severity": "P1", "dimension": "d2", "file_line": "client.go:44", "issue": "...", "remediation": "..."}
  ],
  "summary": "one paragraph"
}
\`\`\`
EOF

invoke_judge() {
  (
    cd "$WORKDIR" || exit 97
    run_with_timeout 1800 claude -p "$(cat "$OUT/judge-prompt.md")${1:-}" \
      --output-format json \
      --plugin-dir "$PLUGIN_ROOT" \
      --allowedTools "Skill,Read,Glob,Grep,Bash(git diff:*),Bash(git log:*)" \
      ${JUDGE_MODEL:+--model "$JUDGE_MODEL"}
  )
}

extract_verdict() { # stdin: claude json envelope → verdict json on stdout, rc!=0 if invalid
  local envelope verdict
  envelope=$(cat)
  verdict=$(jq -r '.result // empty' <<<"$envelope" 2>/dev/null \
    | sed -n '/^```/,/^```/p' | sed '1d;$d')
  # Tolerate a bare (unfenced) JSON final message too.
  if [[ -z "$verdict" ]]; then
    verdict=$(jq -r '.result // empty' <<<"$envelope" 2>/dev/null)
  fi
  jq -e '.overall != null and .dimensions != null and (.assertions | type == "array")' <<<"$verdict" >/dev/null 2>&1 || return 1
  printf '%s' "$verdict"
}

log "judging run in $WORKDIR (status=$RUN_STATUS)"
envelope=$(invoke_judge) || true
printf '%s' "$envelope" > "$OUT/judge-envelope.json"
verdict=$(extract_verdict <<<"$envelope") || {
  warn "verdict parse failed — retrying once with a JSON-only nudge"
  envelope=$(invoke_judge $'\n\nIMPORTANT: your previous output was not valid JSON. Respond with ONLY the fenced ```json verdict block.') || true
  printf '%s' "$envelope" > "$OUT/judge-envelope.json"
  verdict=$(extract_verdict <<<"$envelope") || fail_soft "verdict invalid after retry"
}

printf '%s\n' "$verdict" > "$OUT/judge-verdict.json"
jq -n \
  --argjson cost "$(jq '.total_cost_usd // null' <<<"$envelope")" \
  --argjson dur "$(jq '.duration_ms // null' <<<"$envelope")" \
  '{judge_error: null, skipped: false, cost_usd: $cost, duration_ms: $dur}' \
  > "$OUT/judge-result.json"
log "judge verdict: overall=$(jq -r '.overall' "$OUT/judge-verdict.json")"
