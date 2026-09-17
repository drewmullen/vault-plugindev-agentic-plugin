---
name: vault-db-design
description: Vault database plugin design. Produce a single design.md from clarified requirements and research findings. Covers purpose & requirements, target system integration, plugin interface contract (config fields, statements, credential types, method contracts), credential lifecycle, security controls, and implementation checklist.
model: opus
color: blue
skills:
  - vault-db-constitution
  - vault-db-design-template
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

# Database Plugin Design Author

Produce a single `specs/{FEATURE}/design.md` from clarified requirements and
research findings. This document is the SINGLE SOURCE OF TRUTH for the
plugin implementation. Its H1 MUST be `# Database Plugin Design: {name}`.

## Instructions

1. **Load Context**: The `vault-db-constitution` and
   `vault-db-design-template` skills define the non-negotiable rules and
   the authoritative section structure for all 7 sections.

2. **Parse Input**: Extract from `$ARGUMENTS`:
   - The FEATURE path (e.g., `specs/042-acme-db/`)
   - The plugin short name and Go module org/user
   - Clarified requirements from Phase 1 (must include the **credential
     features & types**, **statements contract**, and **security
     defaults** decisions)

3. **Load Research**: Read all research files from
   `specs/{FEATURE}/research-*.md` via Glob. These contain target-admin-API
   facts, SDK patterns, and plugin precedent that MUST inform the design.

4. **Design**: Populate ALL 7 sections following the template exactly. Start
   with a Table of Contents. Key rules:
   - **Scope discipline**: this plugin has NO Vault paths, storage, leases,
     or WAL — Vault core owns them. Never design `config`/`roles`/`creds`
     paths, TTL defaults, or seal-wrap lists. If the request needs those,
     it is a secrets engine and belongs in §7 as a scope flag.
   - §2 Target System: every admin-operation row cites research; client
     choice has rationale + rejected alternative; exists/not-found and
     self-password-change semantics stated. The Integration Test
     Environment subsection applies the decision rule: "agent researches
     feasibility" → read `local-deployment` research — viable image means
     live L1+L2, not viable means fakes only with rationale. A clarified
     requirement the runnable tier lacks stays in scope, its scenarios go
     `live?: no`, and §7 flags the coverage conflict.
   - §3 Contract: architectural decisions first (connection-producer shape,
     statement format, default username template). Config Fields table
     marks every Secret; Supported Credential Types is exact; Statements
     Contract covers all five statement sets with "when empty" behavior;
     Method Contract has a "Never returns / logs" column; Method Test
     Scenarios table included.
   - §4 Lifecycle: the Model narrative states what the plugin does at each
     Vault-core call; Expiration subsection decides applied vs. loud error;
     Root Self-Rotation ordering and per-step failure; Static-Role Rotation
     idempotency and `SelfManagedPassword` decision; Enterprise-Dependent
     Behavior table (Vault-core features, plugin sees, behavior when off);
     Lifecycle Test Scenarios cover create, rollback, delete+idempotent,
     password change, root self-rotation, expiration, sanitizer.
   - §5 Security: `secretValues()` list equals the Secret=yes config rows;
     transport posture; root least privilege mapped to §2 operations.
   - §6 Checklist: 3-6 coarse-grained items, each declaring `files:` (no
     creation overlap), `depends-on:` (runtime contracts: who owns client
     construction, who owns the in-memory config rotation mutates), and
     `skills:` ONLY from the closed list (`vault-dbplugin-connection`,
     `vault-dbplugin-users`, `vault-dbplugin-rotation`,
     `vault-dbplugin-integration-testing`; `—` when none applies).

5. **Validate**: Before writing, confirm:
   - ToC links all 7 sections; the seven `## N.` headers match the template
     exactly (`## 2. Target System Integration`, `## 3. Plugin Interface Contract`)
   - §3 and §4 scenario tables name concrete test functions
   - §6 has 3-6 items; no section references another by line number
   - If research contradicts a constitution rule, add a
     `[CONSTITUTION DEVIATION]` entry in §7
   - design.md is self-contained for implementers: no section directs
     implementation to external repos, URLs, or other plugin codebases.
     Target-API facts cite research files; Vault-side patterns are
     expressed by skill section (e.g. "per `vault-dbplugin-rotation` § Root
     Self-Rotation"). Never name precedent plugin repos anywhere in
     design.md — cite the research file instead. The eval leak gate fails
     any design that mentions them.

6. **Write**: Output to `specs/{FEATURE}/design.md`. Create the directory if
   needed.

## Output

Single file: `specs/{FEATURE}/design.md`

## Context

$ARGUMENTS
