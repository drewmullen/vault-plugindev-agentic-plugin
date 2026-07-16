#!/usr/bin/env bash
# PreToolUse guard: keep file-tool access inside the tree the workflows own.
#
# Enforces the self-containment contract mechanically:
#   - Read/Grep/Write/Edit paths must be inside the working repository, the
#     installed plugin (read-only), the Go module cache (read-only, for
#     inspecting declared dependencies' source), or temp dirs.
#   - Sensitive credential files are denied everywhere (.vault-token, ~/.ssh,
#     ~/.aws, *.pem, .env) — the workflows never need them; the validator's
#     smoke test uses only the local `vault server -dev` root token.
#   - Path traversal ('..') is denied outright.
#
# $1 = harness dialect, selects the block exit code:
#   claude, cursor -> exit 2   (their documented "deny" signal)
#   copilot        -> exit 1   (Copilot denies on non-zero-EXCEPT-2)
# $2 = plugin root (Claude Code passes ${CLAUDE_PLUGIN_ROOT} from hooks.json)
#
# Fail-open by design on unparseable payloads (only the deny exit code
# blocks). Keep this script dependency-free (sed/grep only, no jq).
set -uo pipefail

DIALECT="${1:-claude}"
PLUGIN_ROOT="${2:-}"

deny() {
  echo "BLOCKED: $1" >&2
  if [ "$DIALECT" = copilot ]; then exit 1; else exit 2; fi
}

payload="$(cat)"

# Target path arrives under file_path/filePath/path in tool_input. First match
# wins; harness payloads put tool_name and tool_input before free-form content.
target="$(printf '%s' "$payload" \
  | sed -nE 's/.*"(file_path|filePath|path)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' \
  | head -n1)"
[ -z "$target" ] && exit 0

tool="$(printf '%s' "$payload" \
  | sed -nE 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
  | head -n1)"

# --- Sensitive credential files: denied everywhere, every tool --------------
case "$target" in
  *.vault-token*|*/.ssh/*|*/.aws/*|*.pem|.env|.env.*|*/.env|*/.env.*)
    deny "sensitive credential file ($target). The workflows never read user credentials; the smoke test uses only the local dev-server token." ;;
esac

# --- Path traversal ----------------------------------------------------------
case "$target" in
  ..|../*|*/..|*/../*)
    deny "path traversal ('..') is not allowed; use paths inside the working repository." ;;
esac

# Relative paths resolve inside the working repository — allowed here.
# (deny-config-writes.sh separately protects governance files in-repo.)
case "$target" in
  /*) ;;
  *) exit 0 ;;
esac

# --- Installed plugin is read-only -------------------------------------------
if [ -n "$PLUGIN_ROOT" ]; then
  case "$target" in
    "$PLUGIN_ROOT"|"$PLUGIN_ROOT"/*)
      if [ "$tool" = "Read" ] || [ "$tool" = "Grep" ]; then
        exit 0
      fi
      deny "the installed plugin is read-only ($target). Plugin changes belong in the plugin's own repository." ;;
  esac
fi

# --- Allowed absolute prefixes ------------------------------------------------
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
gomodcache="${GOMODCACHE:-$HOME/go/pkg/mod}"
usertmp="${TMPDIR:-/tmp}"

for p in "$proj" "$gomodcache" "$usertmp" /tmp /private/tmp /var/folders /private/var/folders; do
  p="${p%/}"
  [ -n "$p" ] || continue
  case "$target" in
    "$p"|"$p"/*)
      # Go module cache is inspect-only.
      if [ "$p" = "${gomodcache%/}" ] && [ "$tool" != "Read" ] && [ "$tool" != "Grep" ]; then
        deny "the Go module cache is read-only ($target)."
      fi
      exit 0 ;;
  esac
done

deny "file access outside the working repository ($target). Vault-side implementation patterns come from the vault-plugin-architecture and vault-plugin-testing skills — do not consult external codebases; web research is for the target system's API only."
