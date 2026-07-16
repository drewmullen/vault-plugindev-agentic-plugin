---
name: vault-judge-criteria
description: Scoring rubric, severity classification, evaluation methodology, and refinement protocol for Vault secrets engine code quality assessment. Use when validating generated plugin code or judging workflow output.
user-invocable: false
---

# Vault Secrets Engine Quality Evaluation Criteria

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

## Security Override

If D2 (Security & Compliance) < 5.0, force "Not Production Ready" regardless
of overall score.

## Severity Classification

- **CRITICAL (P0)**: constitution MUST violations, secret material in logs/errors/undeclared responses, missing seal-wrap on secret-bearing config, revoke depending on role existence, `math/rand` for secrets, build/vet/test failures
- **HIGH (P1)**: constitution SHOULD violations, missing WAL around external mutation, non-idempotent revoke, Enterprise feature that breaks OSS load, missing existence checks
- **MEDIUM (P2)**: code quality issues, missing table cases from design scenario tables, formatting violations, unversioned storage entries
- **LOW (P3)**: style improvements, doc gaps, refactoring opportunities

## Evidence Requirements Per Dimension

- D1: path/field mismatches vs design §3 with file:line; direct SDK/HTTP calls bypassing the client seam
- D2: file:line + severity + code fix for every leak/gap; quote the offending log/error string
- D3: convention violations with file:line; swallowed errors; wrong error channel (user error returned as Go error or vice versa)
- D4: lifecycle gaps vs design §4 with scenario references; WAL ordering quotes
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
