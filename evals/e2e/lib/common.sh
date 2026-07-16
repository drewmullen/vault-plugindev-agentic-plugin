#!/usr/bin/env bash
# Shared helpers for the e2e eval harness. Sourced, bash-3.2 compatible.

EVAL_ROOT="${EVAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
# The plugin repo root (this harness lives at <root>/evals/e2e).
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$EVAL_ROOT/../.." && pwd)}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# Portable timeout: GNU timeout (Linux), gtimeout (brew coreutils), else a
# pure-bash watchdog (TERM after N secs, KILL 60s later; returns 143 not 124).
run_with_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null; then
    timeout --kill-after=60 "$secs" "$@"
  elif command -v gtimeout >/dev/null; then
    gtimeout --kill-after=60 "$secs" "$@"
  else
    local cmd_pid watch_pid rc
    "$@" & cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 60; kill -KILL "$cmd_pid" 2>/dev/null ) &
    watch_pid=$!
    wait "$cmd_pid"; rc=$?
    kill "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
    return "$rc"
  fi
}
