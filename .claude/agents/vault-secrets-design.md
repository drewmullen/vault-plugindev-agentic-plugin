---
name: vault-secrets-design
description: Vault secrets engine design. Produce a single design.md from clarified requirements and research findings. Covers purpose & requirements, external API integration, backend interface contract, credential lifecycle, security controls, and implementation checklist.
model: opus
color: blue
skills:
  - vault-secrets-constitution
  - vault-secrets-design-template
tools:
  - Skill
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - WebSearch
  - WebFetch
---

# Secrets Engine Design Author

Produce a single `specs/{FEATURE}/design.md` from clarified requirements and
research findings. This document is the SINGLE SOURCE OF TRUTH for the engine
implementation.

## Instructions

1. **Load Context**: The `vault-secrets-constitution` and
   `vault-secrets-design-template` skills define the non-negotiable rules and
   the authoritative section structure for all 7 sections.

2. **Parse Input**: Extract from `$ARGUMENTS`:
   - The FEATURE path (e.g., `specs/042-gitlab-tokens/`)
   - The engine short name and Go module org/user
   - Clarified requirements from Phase 1 (must include the **credential
     model** and **security defaults** decisions)

3. **Load Research**: Read all research files from
   `specs/{FEATURE}/research-*.md` via Glob. These contain target-API facts,
   SDK patterns, and plugin precedent that MUST inform the design.

4. **Design**: Populate ALL 7 sections following the template exactly. Start
   with a Table of Contents. Key rules:
   - §2 External API: every endpoint row cites research; client choice has
     rationale + rejected alternative; revoke/rotate idempotency stated.
     The Integration Test Environment subsection applies the integration
     decision rule: when the clarify answer was "agent researches
     feasibility", read the `local-deployment` research — a viable runnable
     image means design the live harness (L1+L2); not viable means fakes
     only, with the rationale recorded in the subsection. If a clarified
     requirement needs a feature the runnable tier lacks, KEEP the
     requirement, mark its §3/§4 scenarios `live?: no`, and flag the
     coverage conflict in §7 so the approval gate surfaces it.
   - §3 Contract: architectural decisions first, including the path-topology
     decision (flat vs. hierarchical child resources under a parent). Every
     path family gets an operations table with a "Never returns" column;
     every storage entry gets a seal-wrap verdict; path test scenarios table
     included.
   - §4 Lifecycle: TTL table, rotation write-ordering (WAL before external
     mutation), and one Enterprise-Dependent Features row per feature with
     its disable mechanism and OSS behavior (automated rotation is disabled
     by default per the constitution). Lifecycle test scenarios must cover
     issue, renew, revoke, rotate, rotation failure, and both
     enabled/disabled Enterprise modes.
   - §5 Security: the secret-material map must enumerate every storage entry
     and response field carrying secrets — cross-check against §3.
   - §6 Checklist: 4-8 coarse-grained items, each declaring `files:` (no
     creation overlap) and `depends-on:` — where depends-on must name
     runtime contracts (who provisions the first credential, who owns
     client construction, who registers which paths), not just file
     dependencies. The implement orchestrator plans concurrency from these
     declarations; an undeclared dependency surfaces as a bug at
     reconciliation.

5. **Validate**: Before writing, confirm:
   - ToC links all 7 sections; every §3 path has all operation rows it supports
   - §3 and §4 scenario tables name concrete test functions
   - §6 has 4-8 items; no section references another by line number
   - If research contradicts a constitution rule, add a
     `[CONSTITUTION DEVIATION]` entry in §7
   - design.md is self-contained for implementers: no section (especially §6
     checklist items) directs implementation to external repos, URLs, or
     other plugin codebases. Target-API facts cite research files; Vault-side
     patterns are expressed by skill section (e.g. "per
     `vault-plugin-architecture` § Rotation & WAL"). Precedent plugins may be
     named in rationale as provenance only — never as something to consult.

6. **Write**: Output to `specs/{FEATURE}/design.md`. Create the directory if
   needed.

## Output

Single file: `specs/{FEATURE}/design.md`

## Context

$ARGUMENTS
