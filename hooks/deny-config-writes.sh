#!/usr/bin/env bash
# PreToolUse guard: deny writes to governance-protected config in the working
# repository. Subagents building a Vault plugin have no business reconfiguring
# the harness (settings, hooks), the installed-plugin manifest, CI, or git
# internals.
#
# Protected (any directory depth):
#   .claude/settings.json, .claude/settings.local.json
#   .claude/hooks/**
#   .claude-plugin/**
#   .github/workflows/**
#   .git/**
#
# $1 = harness dialect, selects the block exit code:
#   claude, cursor -> exit 2   (their documented "deny" signal)
#   copilot        -> exit 1   (Copilot denies on non-zero-EXCEPT-2)
#
# The target path arrives under a "file_path"/"path"/"filePath" key in the
# JSON payload on stdin. JSON escaping (inner quotes become \") keeps this
# match anchored to the real argument, not filenames mentioned in file content.
set -euo pipefail

if grep -qE '"(file_path|path|filePath)"[[:space:]]*:[[:space:]]*"([^"]*/)?(\.claude/settings(\.local)?\.json|\.claude/hooks/[^"]+|\.claude-plugin/[^"]+|\.github/workflows/[^"]+|\.git/[^"]+)"'; then
  echo "BLOCKED: governance-protected config file. Harness settings, hooks, plugin manifests, CI workflows, and git internals are not modified by the workflows; edit manually if a change is genuinely required." >&2
  [ "${1:-}" = copilot ] && exit 1 || exit 2
fi
exit 0
