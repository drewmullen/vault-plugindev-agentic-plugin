#!/usr/bin/env bash
# Post-hoc deterministic gates for a /vault-secrets-e2e run. Re-runs tools in
# the workdir for trustworthy exit codes (no transcript parsing) and writes a
# checks.json summary. Exits nonzero if any check FAILs.
#
# Usage: deterministic.sh --workdir <dir> --out <checks.json>
#
# Checks:
#   design_doc          exactly one specs/*/design.md with all 7 section headers
#   checklist_complete  every §6 checklist item is checked [x]
#   checklist_depends_on every §6 item declares depends-on:
#   leak_check          no clean-room precedent-repo names outside research Sources
#   review_report       specs/*/reports/review_*.md exists
#   validation_report   specs/*/reports/validation_*.md exists
#   gofmt               gofmt -l on the workdir is empty
#   go_build            go build ./... passes
#   go_vet              go vet ./... passes
#   go_test             go test ./... passes
#
# Requires an effective Go toolchain >= 1.24 on PATH (Go's automatic toolchain
# switching counts: a 1.21+ base `go` that can satisfy a `go 1.24` module).
set -uo pipefail
CHECKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CHECKS_DIR/../lib/common.sh"

WORKDIR="" OUT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --workdir) WORKDIR=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) die "deterministic.sh: unknown arg $1" ;;
  esac
done
[[ -d "$WORKDIR" && -n "$OUT" ]] || die "usage: deterministic.sh --workdir <dir> --out <checks.json>"

# ---- prerequisite: effective Go >= 1.24 (probed in isolation so a workdir
# ---- with no go.mod doesn't skew the probe) ----
command -v go >/dev/null || die "go not found on PATH (>= 1.24 required)"
probe=$(mktemp -d)
printf 'module probe\n\ngo 1.24\n' > "$probe/go.mod"
GOVER=$(cd "$probe" && go env GOVERSION 2>/dev/null || true)
rm -rf "$probe"
major=$(printf '%s' "$GOVER" | sed 's/^go//' | cut -d. -f1 | tr -cd '0-9')
minor=$(printf '%s' "$GOVER" | sed 's/^go//' | cut -d. -f2 | tr -cd '0-9')
if [[ -z "$major" || -z "$minor" ]] || ! { [[ "$major" -gt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -ge 24 ]]; }; }; then
  die "effective Go toolchain is '${GOVER:-unknown}' — >= 1.24 required (install a newer go or enable GOTOOLCHAIN=auto)"
fi

LEAK_PATTERN='openldap|secrets-terraform'

RESULTS='{}'
FAILED=0
record() { # record <name> <pass|fail|skip> <detail> [duration_s]
  local name=$1 outcome=$2 detail=$3 dur=${4:-null}
  RESULTS=$(jq -c --arg n "$name" --arg o "$outcome" --arg d "$detail" --argjson t "$dur" \
    '. + {($n): {pass: ($o == "pass"), skipped: ($o == "skip"), detail: $d, duration_s: $t}}' <<<"$RESULTS")
  [[ "$outcome" == "fail" ]] && FAILED=1
  printf 'check %-22s %s%s\n' "$name" "$(printf '%s' "$outcome" | tr '[:lower:]' '[:upper:]')" "${detail:+ ($detail)}"
}

timed() { # timed <name> <cmd...> — pass/fail from exit code, capture output tail
  local name=$1; shift
  local t0 t1 out rc
  t0=$(date +%s)
  out=$( (cd "$WORKDIR" && "$@") 2>&1 ); rc=$?
  t1=$(date +%s)
  if [[ $rc -eq 0 ]]; then
    record "$name" pass "" $((t1 - t0))
  else
    record "$name" fail "$(tail -c 400 <<<"$out" | tr '\n' ' ' | tr -d '"')" $((t1 - t0))
  fi
}

# Section 6 body of the design doc (between "## 6." and the next "## N.").
section6() { awk '/^## 6\./{f=1; next} /^## [0-9]/{f=0} f' "$1"; }
checklist_items() { section6 "$1" | grep -E '^[[:space:]]*[-*] \[.\]' || true; }

# ---- (a) design doc: exactly one, all 7 section headers ----
DESIGN=""
design_count=$(find "$WORKDIR/specs" -mindepth 2 -maxdepth 2 -name design.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$design_count" != "1" ]]; then
  record design_doc fail "expected exactly 1 specs/*/design.md, found $design_count"
else
  DESIGN=$(find "$WORKDIR/specs" -mindepth 2 -maxdepth 2 -name design.md | head -1)
  missing=""
  for header in "## 1. Purpose" "## 2. External API" "## 3. Backend Interface" \
                "## 4. Credential Lifecycle" "## 5. Security Controls" \
                "## 6. Implementation Checklist" "## 7. Open Questions"; do
    grep -q "^$header" "$DESIGN" || missing="$missing '$header'"
  done
  if [[ -z "$missing" ]]; then record design_doc pass "$(basename "$(dirname "$DESIGN")")/design.md"
  else record design_doc fail "missing headers:$missing"; fi
fi

# ---- (b) every §6 checklist item is [x] ----
if [[ -z "$DESIGN" ]]; then
  record checklist_complete fail "no design doc"
else
  items=$(checklist_items "$DESIGN")
  unchecked=$(grep -cE '^[[:space:]]*[-*] \[ \]' <<<"$items" 2>/dev/null || true)
  total=$(grep -c . <<<"$items" 2>/dev/null || true)
  if [[ "${total:-0}" -eq 0 ]]; then
    record checklist_complete fail "no checklist items found in §6"
  elif [[ "${unchecked:-0}" -gt 0 ]]; then
    record checklist_complete fail "$unchecked of $total items unchecked"
  else
    record checklist_complete pass "$total items all [x]"
  fi
fi

# ---- (c) every §6 item declares depends-on: ----
if [[ -z "$DESIGN" ]]; then
  record checklist_depends_on fail "no design doc"
else
  items=$(checklist_items "$DESIGN")
  total=$(grep -c . <<<"$items" 2>/dev/null || true)
  without=$(grep -cv 'depends-on:' <<<"$items" 2>/dev/null || true)
  if [[ "${total:-0}" -eq 0 ]]; then
    record checklist_depends_on fail "no checklist items found in §6"
  elif [[ "${without:-0}" -gt 0 ]]; then
    record checklist_depends_on fail "$without of $total items missing depends-on:"
  else
    record checklist_depends_on pass ""
  fi
fi

# ---- (d) clean-room leak check ----
# design.md: any precedent-repo mention fails. research-*.md: mentions are
# citations, allowed only on/after each file's '### Sources' line.
if [[ -z "$DESIGN" ]]; then
  record leak_check fail "no design doc"
else
  leaks=""
  if grep -qiE "$LEAK_PATTERN" "$DESIGN"; then
    leaks="design.md"
  fi
  while IFS= read -r rf; do
    [[ -n "$rf" ]] || continue
    first_hit=$(grep -inE "$LEAK_PATTERN" "$rf" | head -1 | cut -d: -f1)
    [[ -n "$first_hit" ]] || continue
    sources_line=$(grep -n -m1 '^### Sources' "$rf" | cut -d: -f1)
    if [[ -z "$sources_line" ]] || [[ "$first_hit" -lt "$sources_line" ]]; then
      leaks="$leaks $(basename "$rf"):$first_hit"
    fi
  done < <(find "$WORKDIR/specs" -mindepth 2 -maxdepth 2 -name 'research-*.md' 2>/dev/null)
  if [[ -z "$leaks" ]]; then record leak_check pass ""
  else record leak_check fail "precedent-repo mentions outside Sources: $leaks"; fi
fi

# ---- (e)/(f) reports exist ----
if compgen -G "$WORKDIR/specs/*/reports/review_*.md" >/dev/null; then
  record review_report pass ""
else
  record review_report fail "no specs/*/reports/review_*.md"
fi
if compgen -G "$WORKDIR/specs/*/reports/validation_*.md" >/dev/null; then
  record validation_report pass ""
else
  record validation_report fail "no specs/*/reports/validation_*.md"
fi

# ---- (g) gofmt -l empty ----
GOFMT_BIN=$(command -v gofmt || true)
[[ -n "$GOFMT_BIN" ]] || GOFMT_BIN="$(go env GOROOT)/bin/gofmt"
if [[ -x "$GOFMT_BIN" ]]; then
  unformatted=$( (cd "$WORKDIR" && "$GOFMT_BIN" -l .) 2>&1 )
  if [[ -z "$unformatted" ]]; then record gofmt pass ""
  else record gofmt fail "unformatted: $(tr '\n' ' ' <<<"$unformatted")"; fi
else
  record gofmt fail "gofmt not found (checked PATH and GOROOT/bin)"
fi

# ---- (h)/(i)/(j) go build / vet / test ----
timed go_build go build ./...
timed go_vet  go vet ./...
timed go_test go test ./...

# ---- summary ----
mkdir -p "$(dirname "$OUT")"
jq -n --argjson checks "$RESULTS" '{
  checks: $checks,
  pass: ([$checks[] | .pass or .skipped] | all)
}' > "$OUT"
log "deterministic checks → $OUT (pass=$(jq -r '.pass' "$OUT"))"
exit "$FAILED"
