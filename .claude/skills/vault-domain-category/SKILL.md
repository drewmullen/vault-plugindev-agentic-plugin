---
name: vault-domain-category
description: 8-category ambiguity taxonomy for Vault secrets engine specifications. Structured scan methodology, prioritization heuristics, and clarification question patterns. Use when scanning secrets engine requirements for ambiguity, missing decision points, or underspecified requirements.
user-invocable: false
---

# Vault Secrets Engine Specification Ambiguity Taxonomy

## Purpose

Detect and reduce ambiguity or missing decision points in secrets engine
requirements. Each category is scanned and marked: Clear / Partial / Missing.

## 8-Category Taxonomy

### 1. Functional Scope & Behavior

- What the engine manages in the external system, and for whom
- Core success criteria ("a Vault client can obtain X and it works against Y")
- Explicit out-of-scope declarations
- Database-shaped detection: if the request is "manage users/credentials in a
  database via SQL/driver" it belongs to the `dbplugin.Database` workflow
  (`/vault-db-plan`), not this one — flag it before anything else

### 2. Credential Model & Data

- **Static rotation** (Vault manages passwords of existing accounts), **dynamic
  ephemeral** (Vault creates and destroys accounts per lease), or **both**
- Entities and relationships: config, roles, and any child resources
- **Path topology**: flat (`config`, `roles/<name>`, `creds/<name>`) vs.
  hierarchical (child resources nested under a parent, e.g. accounts under
  hosts: `hosts/<host>/accounts/<name>`)
- Identity and uniqueness rules (what keys a role/resource, collision behavior)

### 3. Lifecycle & Day-2 Operations

- Default/max TTLs; renewal allowed or not; what revocation does externally
- Rotation: manual endpoints, automated (Rotation Manager — Enterprise),
  root credential rotation, rotation cadence
- First-touch bootstrap: for credentials the engine will rotate but not
  create, how does Vault learn their identity initially — import at
  role/config write time, discover via a target-system API call, or an
  explicit initialize endpoint? Surface as a Phase-1 clarify question
  whenever static/rotated credentials are in scope
- Crash recovery expectations (WAL replay after failed rotation)
- What happens to issued credentials when a role or config is deleted

### 4. Non-Functional Quality Attributes

- Credential issuance latency tolerance; expected request volume
- HA/replication behavior (WAL is node-local; performance standbys forward writes)
- Observability (what gets logged — never secret values)
- Compliance constraints (audit expectations, seal wrap requirements)

### 5. Integration & External Dependencies

- Target API auth model (token, basic, OAuth2, mTLS) and how Vault's root
  credential is provisioned
- Endpoints needed for each lifecycle operation; pagination; idempotency
- Rate limits and throttling behavior; error semantics (404 vs 403 vs 409)
- Client choice: official Go SDK vs. plain `net/http`
- Network reachability from the Vault server to the target system

### 6. Edge Cases & Failure Handling

- Revocation races (lease expires while external system is down)
- Rotation failure mid-flight (new secret set externally but not persisted, or
  vice versa)
- External account deleted out-of-band; orphaned credentials
- Quota/limit exhaustion in the target system; lease-expiry storms
- Config deleted or unreachable while leases are outstanding

### 7. Constraints & Tradeoffs

- OSS vs. Enterprise: which features degrade and how (automated rotation off
  by default; manual rotation everywhere)
- Go module path — GitHub org/user name (required to scaffold `go.mod`)
- Go/SDK version constraints; explicit rejected alternatives

### 8. Terminology & Consistency

- Canonical names for paths and fields (`roles` vs `accounts` vs target-system
  vocabulary)
- Consistent singular/plural and casing across paths, storage keys, and docs

## Bonus Categories (check but lower priority)

- **Completion Signals**: acceptance criteria testability, measurable DoD indicators
- **Misc / Placeholders**: TODO markers, ambiguous adjectives ("secure",
  "short-lived", "least privilege") lacking quantification

## Prioritization Heuristic

Rank by `Impact x Uncertainty`:

- High impact + high uncertainty → ask first
- Low impact regardless of uncertainty → skip or defer
- Categories already Clear → skip entirely

## Question Constraints

- Maximum 5 questions per session
- Two question slots are **mandatory** and count toward the maximum:
  1. **Credential model** — static rotation vs. dynamic ephemeral vs. both
  2. **Security defaults** — default/max TTLs, seal-wrap candidates,
     root-credential scope: applied as-proposed vs. customized
- If the Go module path is unknown, the GitHub org/user question is also
  mandatory
- Each question must be answerable with multiple-choice (2-5 options) or a
  short answer (≤5 words)
- Only include questions whose answers materially impact: path design, storage
  schema, lifecycle behavior, test design, or security posture

## Question Exclusions

- Already answered in the request
- Trivial stylistic preferences
- Implementation-level details that don't block design (unless correctness-blocking)

## Vault-Specific Focus Areas

When scanning secrets engine specs, pay special attention to:

- Credential model ambiguity (static vs. dynamic changes everything downstream)
- Path topology (flat vs. hierarchical child resources)
- Root credential least-privilege scope in the target system
- TTL strategy and revocation semantics
- Rotation ownership (who rotates, when, and what happens on failure)
- First-touch bootstrap for rotated-but-not-created credentials (import at
  write vs. API discovery vs. initialize endpoint)
- Enterprise-dependent features and their disabled behavior on OSS Vault
