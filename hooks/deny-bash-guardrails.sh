#!/usr/bin/env bash
# PreToolUse guard for Bash: block commands the workflows promise never to run.
#
#   - history rewrites (git push --force / -f / --force-with-lease)
#   - merging or deleting on GitHub (humans merge PRs; nothing deletes repos)
#   - authenticating to a real Vault (`vault login`) — smoke tests use only
#     the local `vault server -dev` root token
#   - mutating machine-global state (git config --global, go env -w)
#   - pipe-to-shell installs, rm -rf on / or ~
#
# $1 = harness dialect, selects the block exit code:
#   claude, cursor -> exit 2   (their documented "deny" signal)
#   copilot        -> exit 1   (Copilot denies on non-zero-EXCEPT-2)
#
# Checks run against the JSON-escaped "command" value from stdin. Patterns are
# deliberately few and high-confidence: false positives train agents to route
# around the guard.
set -uo pipefail

DIALECT="${1:-claude}"

deny() {
  echo "BLOCKED: $1" >&2
  if [ "$DIALECT" = copilot ]; then exit 1; else exit 2; fi
}

payload="$(cat)"

cmd="$(printf '%s' "$payload" \
  | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
  | head -n1)"
[ -z "$cmd" ] && exit 0

check() { printf '%s' "$cmd" | grep -qE "$1"; }

if check 'git[[:space:]]+push[^|;&]*[[:space:]](--force([[:space:]=]|$)|--force-with-lease|-f([[:space:]]|$))'; then
  deny "force-push rewrites history; checkpoint commits must remain intact. Push normally or ask the user."
fi

if check 'gh[[:space:]]+pr[[:space:]]+merge'; then
  deny "the workflows create PRs; humans merge them."
fi

if check 'gh[[:space:]]+repo[[:space:]]+delete'; then
  deny "repository deletion is never part of the workflows."
fi

if check 'vault[[:space:]]+login'; then
  deny "never authenticate to a real Vault cluster; the validator's smoke test uses only the local 'vault server -dev' root token."
fi

if check 'git[[:space:]]+config[[:space:]]+--global'; then
  deny "no machine-global git config changes; use repo-local config if needed."
fi

if check 'go[[:space:]]+env[[:space:]]+-w'; then
  deny "no machine-global Go env changes; set variables per-invocation instead."
fi

if check '(curl|wget)[^|;&]*\|[[:space:]]*(ba|z|da)?sh'; then
  deny "pipe-to-shell execution is not allowed; download to a file and inspect it if genuinely needed."
fi

if check 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+(~/?|/)([[:space:]"]|$)'; then
  deny "recursive delete of / or ~ is not allowed."
fi

exit 0
