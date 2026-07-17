#!/usr/bin/env bash
# PostToolUse gate: validate spec artifacts the moment they are written, so
# the violation lands on the agent that wrote the file while it is still
# in-context (exit 2 feeds stderr back to that agent).
#
# Scope: Write/Edit/MultiEdit calls targeting
#   specs/*/research-*.md  — precedent-repo names allowed ONLY on/after the
#                            file's '### Sources' line
#   specs/*/design.md      — precedent-repo names never allowed; every §6
#                            checklist item must declare files: and depends-on:
#
# Mirrors evals/e2e/checks/deterministic.sh (leak_check, checklist_depends_on)
# — passing this hook implies passing those checks. The vault-secrets-plan
# orchestrator gates remain as backstop.
#
# $1 = harness dialect: claude/cursor signal on exit 2, copilot on exit 1
set -uo pipefail

DIALECT="${1:-claude}"

LEAK_PATTERN='vault-plugin-(secrets|auth|database)-[a-z-]+|openldap'

deny() {
  echo "SPEC GATE: $1" >&2
  if [ "$DIALECT" = copilot ]; then exit 1; else exit 2; fi
}

payload="$(cat)"

target="$(printf '%s' "$payload" \
  | sed -nE 's/.*"(file_path|filePath|path)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' \
  | head -n1)"
[ -n "$target" ] || exit 0
[ -f "$target" ] || exit 0

case "$target" in
  */specs/*/research-*.md|specs/*/research-*.md)
    # Violations = leak-pattern hits BEFORE the '### Sources' heading
    # (or anywhere, if the file has no Sources heading).
    sources_line="$(grep -n -m1 '^### Sources' "$target" | cut -d: -f1)"
    hits="$(grep -n -iE "$LEAK_PATTERN" "$target" | cut -d: -f1)"
    [ -n "$hits" ] || exit 0
    for line in $hits; do
      if [ -z "$sources_line" ] || [ "$line" -lt "$sources_line" ]; then
        deny "precedent-repo name at $(basename "$target"):$line, outside the '### Sources' section. Findings must describe patterns generically; repo names/URLs belong only under '### Sources'. Rewrite that line now — the eval leak check fails the run on it."
      fi
    done
    ;;
  */specs/*/design.md|specs/*/design.md)
    if grep -n -iE "$LEAK_PATTERN" "$target" >/dev/null; then
      deny "design.md must never name precedent plugin repos ($(grep -n -iE "$LEAK_PATTERN" "$target" | cut -d: -f1 | head -3 | tr '\n' ' ' | sed 's/ $//')) — cite the research file instead (e.g. 'per research-plugin-precedent'). Fix now; the eval leak check fails the run on it."
    fi
    # §6 compliance — only once a §6 section exists (skip partial drafts).
    if grep -q '^## 6\.' "$target"; then
      sec6="$(awk '/^## 6\./{f=1;next} /^## [0-9]/{f=0} f' "$target")"
      items=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\]' || true)
      if [ "${items:-0}" -gt 0 ]; then
        with_files=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\].*files:' || true)
        with_deps=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\].*depends-on:' || true)
        [ "$with_files" -eq "$items" ] || deny "§6: only $with_files of $items checklist items declare 'files:'. Every item needs an explicit files: scope. Fix now."
        [ "$with_deps" -eq "$items" ] || deny "§6: only $with_deps of $items checklist items declare 'depends-on:'. Every item needs depends-on: (naming runtime contracts, '—' if none). Fix now — the eval checklist_depends_on check fails the run without it."
      fi
    fi
    ;;
esac

exit 0
