#!/usr/bin/env bash
# PostToolUse gate: validate spec artifacts the moment they are written, so
# the violation lands on the agent that wrote the file while it is still
# in-context (exit 2 feeds stderr back to that agent).
#
# Scope: Write/Edit/MultiEdit calls targeting
#   specs/*/research-*.md  — precedent-repo names allowed ONLY on/after the
#                            file's '### Sources' line
#   specs/*/design.md      — precedent-repo names never allowed; every §6
#                            checklist item must declare files:, depends-on:,
#                            and skills: (closed activity-skill list or —;
#                            secrets-engine and database-plugin lists both valid)
#
# "Precedent-repo name" = any vault-plugin-{secrets,auth,database}-* name
# (plus the clean-room source orgs) EXCEPT the plugin's own module/binary
# name, which the design must state (Go Module line, cmd/<binary>/main.go).
# The own name is derived from the sibling design.md's '**Go Module**' line
# and from the feature directory's short name (specs/NNN-<short-name>/).
#
# Mirrors evals/e2e/checks/deterministic.sh (leak_check, checklist_depends_on,
# checklist_skills) — passing this hook implies passing those checks. The
# vault-secrets-plan / vault-db-plan orchestrator gates remain as backstop.
#
# $1 = harness dialect: claude/cursor signal on exit 2, copilot on exit 1
set -uo pipefail

DIALECT="${1:-claude}"

LEAK_PATTERN='vault-plugin-(secrets|auth|database)-[a-z0-9-]+|openldap|hashi-demo-lab|plugins/database/'

# own_names <spec-file> → ERE alternation of the plugin's own names, or empty.
own_names() {
  local dir names mod short
  dir="$(dirname "$1")"
  names=""
  mod="$(grep -m1 -E '^\*\*Go Module\*\*' "$dir/design.md" 2>/dev/null \
    | grep -oE 'vault-plugin-(secrets|auth|database)-[a-z0-9-]+' | head -n1)"
  [ -n "$mod" ] && names="$mod"
  short="$(basename "$dir" | sed -E 's/^[0-9]+-//' | tr -cd 'a-z0-9-')"
  [ -n "$short" ] && names="${names:+$names|}vault-plugin-(secrets|auth|database)-$short"
  printf '%s' "$names"
}

# scrub <spec-file> → the file with own names blanked (whole-token matches
# only; line count preserved so grep -n line numbers stay valid).
scrub() {
  local own
  own="$(own_names "$1")"
  if [ -n "$own" ]; then
    sed -E "s/($own)([^a-z0-9-]|\$)/\2/g" "$1"
  else
    cat "$1"
  fi
}

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
    hits="$(scrub "$target" | grep -n -iE "$LEAK_PATTERN" | cut -d: -f1)"
    [ -n "$hits" ] || exit 0
    for line in $hits; do
      if [ -z "$sources_line" ] || [ "$line" -lt "$sources_line" ]; then
        deny "precedent-repo name at $(basename "$target"):$line, outside the '### Sources' section. Findings must describe patterns generically; repo names/URLs belong only under '### Sources'. Rewrite that line now — the eval leak check fails the run on it."
      fi
    done
    ;;
  */specs/*/design.md|specs/*/design.md)
    design_hits="$(scrub "$target" | grep -n -iE "$LEAK_PATTERN" | cut -d: -f1 | head -3 | tr '\n' ' ' | sed 's/ $//')"
    if [ -n "$design_hits" ]; then
      deny "design.md must never name precedent plugin repos (lines: $design_hits) — cite the research file instead (e.g. 'per research-plugin-precedent'). The plugin's OWN module/binary name is exempt. Fix now; the eval leak check fails the run on it."
    fi
    # §6 compliance — only once a §6 section exists (skip partial drafts).
    if grep -q '^## 6\.' "$target"; then
      sec6="$(awk '/^## 6\./{f=1;next} /^## [0-9]/{f=0} f' "$target")"
      items=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\]' || true)
      if [ "${items:-0}" -gt 0 ]; then
        with_files=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\].*files:' || true)
        with_deps=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\].*depends-on:' || true)
        with_skills=$(printf '%s\n' "$sec6" | grep -c '^- \[[ x]\].*skills:' || true)
        [ "$with_files" -eq "$items" ] || deny "§6: only $with_files of $items checklist items declare 'files:'. Every item needs an explicit files: scope. Fix now."
        [ "$with_deps" -eq "$items" ] || deny "§6: only $with_deps of $items checklist items declare 'depends-on:'. Every item needs depends-on: (naming runtime contracts, '—' if none). Fix now — the eval checklist_depends_on check fails the run without it."
        [ "$with_skills" -eq "$items" ] || deny "§6: only $with_skills of $items checklist items declare 'skills:'. Every item needs skills: (activity skill name(s) from the design template's closed list, '—' if none). Fix now — the eval checklist_skills check fails the run without it."
        VALID_SKILLS='vault-plugin-config-client|vault-plugin-dynamic-roles|vault-plugin-dynamic-creds|vault-plugin-static-roles|vault-plugin-integration-testing|vault-dbplugin-connection|vault-dbplugin-users|vault-dbplugin-rotation|vault-dbplugin-integration-testing'
        bad_skills=$(printf '%s\n' "$sec6" | grep '^- \[[ x]\].*skills:' | sed -E 's/.*skills:[[:space:]]*//' | grep -oE 'vault-(db)?plugin-[a-z-]+' | grep -vE "^($VALID_SKILLS)$" || true)
        [ -z "$bad_skills" ] || deny "§6: unknown skills: value(s): $(printf '%s' "$bad_skills" | tr '\n' ' '). Use only the design template's closed list: ${VALID_SKILLS//|/, } (or '—'). Fix now."
      fi
    fi
    ;;
esac

exit 0
