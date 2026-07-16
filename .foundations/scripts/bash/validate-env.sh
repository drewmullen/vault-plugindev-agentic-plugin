#!/usr/bin/env bash

# Environment validation script with GATE/WARN severity classification
#
# Each check is classified as:
#   GATE — Failure blocks all progress. Orchestrators MUST NOT proceed.
#   WARN — Failure degrades capability but does not block progress.
#
# Usage: ./validate-env.sh [OPTIONS]
#
# OPTIONS:
#   --json              Output in JSON format (includes gate_passed boolean)
#   --help, -h          Show help message
#
# EXIT CODES:
#   0: All checks passed (GATE and WARN)
#   1: One or more GATE checks failed — orchestrators MUST stop
#   2: All GATE checks passed but one or more WARN checks failed

set -euo pipefail

# Minimum supported Go minor version (1.x)
GO_MIN_MINOR=24

# Parse command line arguments
JSON_MODE=false

for arg in "$@"; do
    case "$arg" in
        --json)
            JSON_MODE=true
            ;;
        --help|-h)
            cat << EOF
Usage: validate-env.sh [OPTIONS]

Validate environment prerequisites for Vault plugin development workflows.

Each check has a severity:
  GATE  Failure blocks all progress. Orchestrators MUST stop.
  WARN  Failure degrades capability. Orchestrators may proceed.

GATE CHECKS:
  GO                 Go toolchain installed (>= 1.${GO_MIN_MINOR})
  GIT_REPO           Current directory is inside a git repository
                     (workflows create feature branches and checkpoint commits)

WARN CHECKS:
  GH_REMOTE          Git remote 'origin' configured
                     (without it: no issue/PR automation; documents still written)
  GH_CLI             GitHub CLI installed and authenticated
                     (without it: issue/PR steps are skipped with a warning)
  GOLANGCI_LINT      golangci-lint installed (lint pipeline, non-blocking)
  VAULT              Vault CLI installed (dev-server smoke mount, non-blocking)

OPTIONS:
  --json              Output in JSON format (includes gate_passed, checks array)
  --help, -h          Show this help message

EXIT CODES:
  0: All checks passed
  1: One or more GATE checks failed — MUST stop
  2: GATE checks passed, one or more WARN checks failed

JSON OUTPUT SCHEMA:
  {
    "gate_passed": true|false,
    "checks": [
      {"name": "GO", "severity": "GATE", "passed": true|false, "detail": "..."},
      ...
    ]
  }

EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option '$arg'. Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# --- Check definitions ---
# Each check: name, severity, passed, detail
declare -a check_names=()
declare -a check_severities=()
declare -a check_passed=()
declare -a check_details=()

add_check() {
    local name="$1" severity="$2" passed="$3" detail="$4"
    check_names+=("$name")
    check_severities+=("$severity")
    check_passed+=("$passed")
    check_details+=("$detail")
}

# GATE: Go toolchain (>= 1.GO_MIN_MINOR)
# NOTE: version extraction uses bash regex instead of piped grep/head to avoid
# SIGPIPE false failures under pipefail.
if ! command -v go &> /dev/null; then
    add_check "GO" "GATE" "false" "NOT INSTALLED — see: https://go.dev/dl/"
else
    GO_RAW="$(go version 2>/dev/null || true)"
    if [[ "$GO_RAW" =~ go([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
        GO_MAJOR="${BASH_REMATCH[1]}"
        GO_MINOR="${BASH_REMATCH[2]}"
        GO_VERSION="${GO_MAJOR}.${GO_MINOR}${BASH_REMATCH[3]:-}"
        if [[ "$GO_MAJOR" -gt 1 ]] || { [[ "$GO_MAJOR" -eq 1 ]] && [[ "$GO_MINOR" -ge "$GO_MIN_MINOR" ]]; }; then
            add_check "GO" "GATE" "true" "INSTALLED (go${GO_VERSION})"
        else
            add_check "GO" "GATE" "false" "VERSION TOO OLD (go${GO_VERSION}) — requires >= 1.${GO_MIN_MINOR}. See: https://go.dev/dl/"
        fi
    else
        add_check "GO" "GATE" "false" "VERSION UNDETECTABLE — 'go version' output unrecognized"
    fi
fi

# GATE: git repository
# Workflows create feature branches and checkpoint commits, so a git repo is
# required. A GitHub remote is NOT required (see GH_REMOTE below).
if git rev-parse --show-toplevel &> /dev/null; then
    add_check "GIT_REPO" "GATE" "true" "DETECTED ($(git rev-parse --show-toplevel))"
else
    add_check "GIT_REPO" "GATE" "false" "NOT A GIT REPOSITORY — run 'git init' first"
fi

# WARN: GitHub remote (origin)
# Without a remote, issue/PR automation is skipped; documents are still
# written to specs/{FEATURE}/ locally.
if git remote get-url origin &> /dev/null; then
    add_check "GH_REMOTE" "WARN" "true" "CONFIGURED ($(git remote get-url origin))"
else
    add_check "GH_REMOTE" "WARN" "false" "NOT CONFIGURED — issue/PR automation will be skipped; documents still written locally"
fi

# WARN: GitHub CLI installed and authenticated
# GH_PROMPT_DISABLED prevents gh auth status from hanging on interactive prompts.
# GH_HOST supports GitHub Enterprise (defaults to github.com).
GH_HOSTNAME="${GH_HOST:-github.com}"
if ! command -v gh &> /dev/null; then
    add_check "GH_CLI" "WARN" "false" "NOT INSTALLED — issue/PR automation unavailable. See: https://cli.github.com"
elif GH_PROMPT_DISABLED=1 gh auth status --hostname "$GH_HOSTNAME" &> /dev/null; then
    add_check "GH_CLI" "WARN" "true" "AUTHENTICATED (${GH_HOSTNAME})"
elif [[ -n "${GH_TOKEN:-}" ]]; then
    add_check "GH_CLI" "WARN" "true" "AUTHENTICATED via GH_TOKEN (${GH_HOSTNAME})"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    add_check "GH_CLI" "WARN" "true" "AUTHENTICATED via GITHUB_TOKEN (${GH_HOSTNAME})"
else
    add_check "GH_CLI" "WARN" "false" "NOT AUTHENTICATED — run 'gh auth login' or export GH_TOKEN; issue/PR automation unavailable"
fi

# WARN: golangci-lint
if command -v golangci-lint &> /dev/null; then
    LINT_RAW="$(golangci-lint --version 2>/dev/null || true)"
    if [[ "$LINT_RAW" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        LINT_VERSION="${BASH_REMATCH[1]}"
    else
        LINT_VERSION="unknown"
    fi
    add_check "GOLANGCI_LINT" "WARN" "true" "INSTALLED (v${LINT_VERSION})"
else
    add_check "GOLANGCI_LINT" "WARN" "false" "NOT INSTALLED — lint pipeline unavailable. See: https://golangci-lint.run"
fi

# WARN: Vault CLI (enables `vault server -dev` smoke mount during validation)
if command -v vault &> /dev/null; then
    VAULT_RAW="$(vault version 2>/dev/null || true)"
    if [[ "$VAULT_RAW" =~ v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        VAULT_VERSION="${BASH_REMATCH[1]}"
    else
        VAULT_VERSION="unknown"
    fi
    add_check "VAULT" "WARN" "true" "INSTALLED (v${VAULT_VERSION})"
else
    add_check "VAULT" "WARN" "false" "NOT INSTALLED — dev-server smoke mount unavailable. See: https://developer.hashicorp.com/vault/install"
fi

# --- Evaluate results ---
gate_failed=0
warn_failed=0
for ((i=0; i<${#check_names[@]}; i++)); do
    if [[ "${check_passed[$i]}" == "false" ]]; then
        if [[ "${check_severities[$i]}" == "GATE" ]]; then
            gate_failed=$((gate_failed + 1))
        else
            warn_failed=$((warn_failed + 1))
        fi
    fi
done

gate_passed="true"
[[ "$gate_failed" -gt 0 ]] && gate_passed="false"

if [[ "$gate_failed" -gt 0 ]]; then
    EXIT_CODE=1
elif [[ "$warn_failed" -gt 0 ]]; then
    EXIT_CODE=2
else
    EXIT_CODE=0
fi

# --- Output ---
if $JSON_MODE; then
    # Build checks JSON array
    checks_json=""
    for ((i=0; i<${#check_names[@]}; i++)); do
        [[ -n "$checks_json" ]] && checks_json+=","
        checks_json+="$(printf '{"name":"%s","severity":"%s","passed":%s,"detail":"%s"}' \
            "${check_names[$i]}" "${check_severities[$i]}" "${check_passed[$i]}" "${check_details[$i]}")"
    done

    printf '{"gate_passed":%s,"checks":[%s]}\n' "$gate_passed" "$checks_json"
else
    echo "Environment Validation"
    echo "======================"
    echo ""

    for ((i=0; i<${#check_names[@]}; i++)); do
        local_severity="${check_severities[$i]}"
        local_name="${check_names[$i]}"
        local_status="Passed"
        [[ "${check_passed[$i]}" == "false" ]] && local_status="FAILED"
        echo "  [$local_severity] $local_name — $local_status — ${check_details[$i]}"
    done

    echo ""
    echo "Summary"
    echo "-------"
    if [[ "$gate_failed" -gt 0 ]]; then
        echo "BLOCKED: $gate_failed GATE check(s) failed. Cannot proceed."
        echo ""
        echo "Quick Setup:"
        step=1
        for ((i=0; i<${#check_names[@]}; i++)); do
            if [[ "${check_passed[$i]}" == "false" && "${check_severities[$i]}" == "GATE" ]]; then
                echo "  $step. ${check_names[$i]}: ${check_details[$i]}"
                step=$((step + 1))
            fi
        done
    elif [[ "$warn_failed" -gt 0 ]]; then
        echo "PASSED (with warnings): All GATE checks passed. $warn_failed WARN check(s) failed."
    else
        echo "ALL PASSED: Environment is fully configured."
    fi
fi

exit "$EXIT_CODE"
