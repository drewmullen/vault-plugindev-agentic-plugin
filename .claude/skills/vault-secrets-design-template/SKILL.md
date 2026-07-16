---
name: vault-secrets-design-template
description: Canonical 7-section structure for a Vault secrets engine design.md — purpose, external API integration, backend interface contract (flat or hierarchical paths), credential lifecycle with Enterprise-dependency notes, security controls, implementation checklist, open questions. Load when authoring or reviewing specs/{FEATURE}/design.md.
user-invocable: false
---

# Vault Secrets Engine Design Template

The design agent writes `specs/{FEATURE}/design.md` following this structure
exactly. `{braces}` mark fill-ins; brace-wrapped paragraphs are guidance to
the author and are NOT copied into the document. Template rules are at the end.

---

# Secrets Engine Design: {engine-name}

**Branch**: {NNN-short-name}
**Date**: {YYYY-MM-DD}
**Status**: Draft | Approved | Implementing | Complete
**Target System**: {external system + API version}
**Go Module**: github.com/{org}/vault-plugin-secrets-{name}
**Go Version**: >= {version}

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [External API Integration](#2-external-api-integration)
3. [Backend Interface Contract](#3-backend-interface-contract)
4. [Credential Lifecycle](#4-credential-lifecycle)
5. [Security Controls](#5-security-controls)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

{One paragraph. What credentials/resources this engine manages in which
external system, who consumes them, what problem it solves.}

**Credential model**: {static rotation | dynamic ephemeral | both} — {one-line rationale}

**Scope boundary**: {What is explicitly OUT of scope — prevents scope creep.}

### Requirements

**Functional requirements** — from Phase 1 clarification:

- {Testable statement of required capability}
- ...

**Non-functional requirements**:

- {Constraint or quality attribute that bounds the design}
- ...

---

## 2. External API Integration

{This section makes "bring your own API" work — filled from research files.}

### Authentication

- **Auth model**: {token / basic / OAuth2 client-credentials / mTLS / ...}
- **Root credential provisioning**: {how the operator obtains and scopes the
  credential Vault stores in config}

### Endpoints Used

| Lifecycle operation | HTTP method + path | Request essentials | Success / error semantics |
|--------------------|--------------------|--------------------|---------------------------|
| {verify config} | {GET /...} | {...} | {200; 401 invalid credential} |
| {create credential} | {POST /...} | {...} | {201; 409 exists; 429 throttle} |
| {revoke credential} | {DELETE /...} | {...} | {204; 404 treated as success} |
| ... | | | |

### Client Choice

**{Official Go SDK vX / plain net/http}**.
*Rationale*: {why, citing research}.
*Rejected*: {alternative and why not}.

### Rate Limits & Error Semantics

- {Documented rate limits; retry/backoff strategy; which errors are user
  errors (logical.ErrorResponse) vs. internal errors}
- {Idempotency notes per endpoint — critical for revoke and rotate}

---

## 3. Backend Interface Contract

### Architectural Decisions

**{Decision title}**: {What was chosen}.
*Rationale*: {Why, citing research findings and/or skill sections. Never
direct implementers to external repos or codebases.}
*Rejected*: {What was considered and why rejected}.

{Must include a path-topology decision: flat (`config`, `roles/<name>`,
`creds/<name>`) or hierarchical (child resources nested under a parent, e.g.
`hosts/<host>/accounts/<name>` — precedent: the OS engine's accounts-under-hosts
layout in public API docs). Hierarchical layouts nest at most one level.}

### Paths

{One sub-table per path family. This is the SINGLE SOURCE OF TRUTH for the
engine's API surface. For hierarchical layouts, name child paths with their
full parent prefix.}

#### `{path pattern, e.g. config or hosts/<host>/accounts/<name>}`

| Operation | Fields (name: type, required, default) | Returns | Never returns |
|-----------|----------------------------------------|---------|---------------|
| write | {...} | {...} | {secret material list} |
| read | — | {...} | {...} |
| delete | — | {...} | — |
| list | — | {keys} | — |

### Storage Entries

| Storage key pattern | Go struct | Fields | Contains secrets | Seal-wrap candidate |
|---------------------|-----------|--------|:---:|:---:|
| `config` | `{configEntry}` | {...} | {Yes/No} | {Yes/No} |
| `{roles/<name>}` | `{roleEntry}` | {...} | {Yes/No} | {Yes/No} |
| ... | | | | |

{Every entry struct carries a Version field per constitution §2.3.}

### Path Test Scenarios

{Table-driven scenarios the test-writer converts into `path_*_test.go`. Every
path family needs at least: happy-path CRUD(+list), validation rejection, and
read-never-returns-secrets where applicable.}

| Scenario | Path | Purpose | Test function |
|----------|------|---------|---------------|
| {Config write/read round-trip, password omitted from read} | `config` | ... | `TestConfig_{...}` |
| ... | | | |

---

## 4. Credential Lifecycle

### Model

{Narrative: how a credential comes into existence, lives, and dies. For static:
what rotation changes and where the current secret is readable. For dynamic:
what `creds/<name>` creates externally, lease attachment, renew/revoke.}

### TTLs & Leases

| Setting | Default | Max | Configurable at |
|---------|---------|-----|-----------------|
| Credential TTL | {1h} | {24h} | {role, mount} |
| ... | | | |

### Rotation

- **Manual**: {endpoints, what they rotate, WAL protection steps}
- **Root rotation**: {rotate-root behavior if applicable}
- **Write-ordering**: {WAL before external mutation; persist only after external
  success; recovery reconciliation on startup}

### Enterprise-Dependent Features

{One entry per feature. REQUIRED for every Enterprise-dependent feature.}

| Feature | Depends on | How disabled | Disabled behavior on OSS Vault |
|---------|-----------|--------------|--------------------------------|
| Automated rotation | Rotation Manager (Enterprise) | `disable_automated_rotation` (default: true) | Manual rotation endpoints work identically; no schedule registered |
| ... | | | |

### Lifecycle Test Scenarios

{Scenarios the test-writer converts into lifecycle tests. Must cover every
transition: issue, renew, revoke, rotate, rotation failure, and both
enabled/disabled modes for each Enterprise-dependent feature.}

| Scenario | Transition | Purpose | Test function |
|----------|-----------|---------|---------------|
| {Creds issue returns declared fields with role TTL} | issue | ... | `TestCreds_{...}` |
| {Revoke succeeds when external credential already gone} | revoke | idempotency | `TestRevoke_{...}` |
| {Rotation failure after external call leaves recoverable WAL} | rotate | crash safety | `TestRotate_{...}` |
| ... | | | |

---

## 5. Security Controls

- **Secret material map**: {every place secret material exists — storage entries
  (from §3 table) and response fields (from §3 paths). Anything else is a bug.}
- **Seal-wrap list**: {storage paths passed to `PathsSpecial.SealWrapStorage`}
- **Root credential least privilege**: {minimum scopes/permissions in the target
  system, mapped to the §2 endpoints}
- **Audit-safe logging**: {what identifiers are logged; confirmation that no
  secret value is logged at any level}
- **Password generation**: {base62 length / password policy support}

---

## 6. Implementation Checklist

{4-8 coarse-grained `- [ ]` items. Each item declares `files:` (created or
modified; if A creates a file, B may modify but not create it) and
`depends-on:` (items that must land first). depends-on covers RUNTIME
contracts, not just files: who provisions the first credential, who owns
client construction, who registers which paths. The implement orchestrator
plans dispatch waves from these declarations — batching or parallelizing
developer agents as the dependencies allow. The test-writer creates the repo
skeleton and all `_test.go` files BEFORE these items run.}

- [ ] **A: {Client & config}** — files: {client.go, path_config.go}; depends-on: —
- [ ] **B: {Roles / resources}** — files: {path_roles.go, ...}; depends-on: A {(client seam)}
- [ ] **C: {Credential issuance}** — files: {path_creds.go, secret_*.go}; depends-on: A, B {(role entries; C provisions first-touch tokens — state it here if another item assumes they exist)}
- [ ] **D: {Rotation & WAL}** — files: {path_rotate.go, wal.go}; depends-on: C {(rotates what C provisions)}
- [ ] **E: {Polish}** — files: {README, Makefile}; depends-on: all

---

## 7. Open Questions

{Deferred decisions marked [DEFERRED] with context; constitution deviations
marked [CONSTITUTION DEVIATION] with rationale. Empty if all resolved.}

---

## Template Rules

1. No section may reference another section by line number
2. Path names and fields appear exactly once — in §3 Paths tables
3. Storage keys appear exactly once — in §3 Storage Entries
4. §2 references external endpoints; §3 references Vault paths — never mix
5. Every test scenario maps 1:1 to a named test function; §3 covers path
   behavior, §4 covers lifecycle transitions (the constitution's coverage
   table in its §6.1 is the minimum bar)
6. §6 items are coarse-grained with explicit `files:` scope (no creation
   overlaps) and explicit `depends-on:` declarations that cover runtime
   contracts (first-credential provisioning, client identity, path
   registration) — not just file dependencies
7. Secret material appears in responses/storage ONLY where §3 declares it;
   §5 must enumerate every occurrence
