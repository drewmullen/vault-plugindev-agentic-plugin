---
name: vault-judge-criteria
description: Scoring rubrics (secrets engine and database plugin), severity classification, evaluation methodology, and refinement protocol for Vault plugin code quality assessment. Use when validating generated plugin code or judging workflow output. Select the rubric by the design.md H1 (Secrets Engine Design vs Database Plugin Design).
user-invocable: false
---

# Vault Plugin Quality Evaluation Criteria

Two rubrics share the principles, scale, severity rules, and report format
below. Pick by the design document's H1: `# Secrets Engine Design:` →
the **Secrets Engine** rubric (`vault-secrets-engine`); `# Database Plugin
Design:` → the **Database Plugin** rubric (`vault-database-plugin`).

## Core Principles

1. **Evidence-Based**: all judgments grounded in observable evidence (file:line, code quotes)
2. **Actionable**: every issue includes concrete remediation with before/after examples
3. **Calibrated**: use the full 1-10 scale, consistent and comparable, ±0.5 variance on re-evaluation
4. **Constitution Authority**: MUST violations = CRITICAL, SHOULD = HIGH, MAY = LOW

## Production Readiness Scale

| Score    | Level          | Action                                |
| -------- | -------------- | ------------------------------------- |
| 9.0-10.0 | Exceptional    | None — use as reference               |
| 8.0-8.9  | Excellent      | Optional refinement                   |
| 7.0-7.9  | Good           | Address high-priority issues          |
| 6.0-6.9  | Adequate       | Fix critical issues before production |
| 5.0-5.9  | Below Standard | Rework required                       |
| 4.0-4.9  | Poor           | Substantial redesign needed           |
| 1.0-3.9  | Unacceptable   | Complete rework required              |

## 6 Evaluation Dimensions (Secrets Engine Workflow)

| #   | Dimension               | Weight | Key Criteria                                                                                                    |
| --- | ----------------------- | ------ | ---------------------------------------------------------------------------------------------------------------|
| 1   | Backend & Path Design   | 25%    | framework.Backend patterns, paths/fields/storage match design §3 exactly, hierarchical layout correctness, client seam integrity |
| 2   | Security & Compliance   | 30%    | Secret hygiene (no secrets in logs/errors/undeclared responses), seal-wrap list implemented, least-privilege root credential, safe password generation. **<5.0 = Not Production Ready** |
| 3   | Code Quality            | 15%    | Go conventions, error handling (`logical.ErrorResponse` vs internal error), locking, storage versioning, file organization |
| 4   | Credential Lifecycle    | 10%    | Lease TTL resolution, idempotent revoke, rotation write-ordering with WAL, Enterprise features degrade per design §4 |
| 5   | Testing                 | 10%    | Constitution §6.1 coverage table met, fakes with error injection, race-clean, both Enterprise modes            |
| 6   | Constitution Alignment  | 10%    | Matches design.md, constitution MUST compliance                                                                 |

**Score formula**: `(D1 x 0.25) + (D2 x 0.30) + (D3 x 0.15) + (D4 x 0.10) + (D5 x 0.10) + (D6 x 0.10)`

## 6 Evaluation Dimensions (Database Plugin Workflow)

Rubric id: `vault-database-plugin`. Same weights and formula as above;
the criteria reflect the `dbplugin.Database` contract (no paths, storage,
leases, or WAL — Vault core owns them).

| #   | Dimension                  | Weight | Key Criteria                                                                                                    |
| --- | -------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------|
| 1   | Interface & Config Design  | 25%    | Correct v5 contract (New + sanitizer middleware, ServeMultiplex, PluginVersion), config fields decoded/validated per design §3, username template honored, statements contract implemented incl. empty behavior, SetSupportedCredentialTypes exact, client seam integrity |
| 2   | Security & Compliance      | 30%    | secretValues() covers every Secret=yes field and reads current state, no statement/secret/URL-with-creds in errors or logs, TLS fields applied with insecure default false, root least privilege documented, no credential generation in plugin. **<5.0 = Not Production Ready** |
| 3   | Code Quality               | 15%    | Go conventions, %w-wrapped errors naming fields not values, one RWMutex with correct lock scope, not-initialized guard, file organization |
| 4   | Credential Lifecycle       | 10%    | NewUser type-gate→parse→render→mutate ordering with rollback, idempotent DeleteUser, UpdateUser password/expiration/public-key per design §4, root self-rotation updates config + rawConfig + client and survives Close/re-Initialize, loud unsupported-expiration error |
| 5   | Testing                    | 10%    | DB constitution §6.1 coverage table met, fake with error injection + call capture, sanitizer redaction test, race-clean                |
| 6   | Constitution Alignment     | 10%    | Matches design.md, DB constitution MUST compliance, no Vault paths/storage/WAL smuggled in                                          |

## Security Override

If D2 (Security & Compliance) < 5.0, force "Not Production Ready" regardless
of overall score.

## Severity Classification

- **CRITICAL (P0)**: constitution MUST violations, secret material in logs/errors/undeclared responses, missing seal-wrap on secret-bearing config, revoke depending on role existence, `math/rand` for secrets, build/vet/test failures; (database) a Secret=yes config field missing from `secretValues()`, statement text in an error, root self-rotation that leaves the in-memory credential stale, non-idempotent `DeleteUser`
- **HIGH (P1)**: constitution SHOULD violations, missing WAL around external mutation, non-idempotent revoke, Enterprise feature that breaks OSS load, missing existence checks; (database) `NewUser` without rollback on partial failure, `InitializeResponse.Config` not echoing the request map, silent no-op on unsupported expiration change, unsupported credential type reaching the target
- **MEDIUM (P2)**: code quality issues, missing table cases from design scenario tables, formatting violations, unversioned storage entries
- **LOW (P3)**: style improvements, doc gaps, refactoring opportunities

## Evidence Requirements Per Dimension

- D1: path/field mismatches vs design §3 with file:line; direct SDK/HTTP calls bypassing the client seam. (database) config-field, credential-type, or statement-contract mismatches vs §3; driver/HTTP calls outside the client
- D2: file:line + severity + code fix for every leak/gap; quote the offending log/error string
- D3: convention violations with file:line; swallowed errors; wrong error channel (user error returned as Go error or vice versa)
- D4: lifecycle gaps vs design §4 with scenario references; WAL ordering quotes. (database) NewUser/UpdateUser/DeleteUser ordering quotes, root self-rotation state updates
- D5: missing test functions vs §3/§4 scenario tables (name them); fake gaps (no error injection)
- D6: design deviations with design.md section refs; constitution violations with section citations

## Refinement Options (when score < 8.0)

- **A (Auto-fix)**: fix all P0 issues, re-evaluate (max 3 iterations)
- **B (Interactive)**: present each issue, show fix, wait for approval
- **C (Manual)**: user fixes, agent provides guidance
- **D (Detailed)**: generate before/after examples for top 10 issues

## Quality Report Format

```markdown
## Quality Score: {FEATURE}

### Overall: {X.X}/10.0 — {Level}

| #   | Dimension             | Score | Issues                             |
| --- | --------------------- | ----- | ---------------------------------- |
| 1   | Backend & Path Design | {X.X} | {count} P0, {count} P1, {count} P2 |
| 2   | Security & Compliance | {X.X} | {count} P0, {count} P1, {count} P2 |
| ... | ...                   | ...   | ...                                |

### Production Readiness: {Ready / Not Ready}

{If Not Ready, list blocking issues}

### Top Issues

| #   | Severity | Dimension | File:Line   | Issue         | Remediation |
| --- | -------- | --------- | ----------- | ------------- | ----------- |
| 1   | {P0-P3}  | {dim}     | {file:line} | {description} | {fix}       |
```
