# Agent Dispatch Flows

How each workflow's orchestrator calls agents. Legend: rectangles = scripts /
mechanical gates, rounded = subagent dispatches (model in parens), diamonds =
decision/loop points, double-border = human gate.

## /vault-secrets-plan (Phases 1–2)

```mermaid
flowchart TD
    A[validate-env.sh gate] --> B[parse args / gh issue / create-new-feature.sh]
    B --> C[taxonomy scan: vault-domain-category]
    C --> D{{AskUserQuestion: clarifications<br/>credential model, security defaults,<br/>module org, integration environment}}
    D --> E1(["research: target-api (haiku)"])
    D --> E2(["research: sdk-patterns (haiku)"])
    D --> E3(["research: plugin-precedent (haiku)"])
    D --> E4(["research: lifecycle-edge-cases (haiku)"])
    D --> E5(["research: local-deployment (haiku)"])
    E1 & E2 & E3 & E4 & E5 --> F[Glob: research-*.md exist]
    F --> G[LEAK GATE: grep research files,<br/>precedent names Sources-only]
    G --> H(["vault-secrets-design (opus)<br/>reads research + template + constitution"])
    H --> I[Glob: design.md exists<br/>grep: 7 sections present]
    I --> J[COMPLIANCE GATE: §6 files:/depends-on:<br/>+ no precedent names]
    J --> K{{AskUserQuestion: design summary<br/>approve / review / request changes}}
    K -->|changes| H
    K -->|approved| L[checkpoint · done →<br/>/vault-secrets-implement]
```

Notes: research agents run as parallel foreground Task calls in one message;
each writes `specs/{FEATURE}/research-{slug}.md` and the orchestrator never
reads their contents (Glob only). The PostToolUse `gate-spec-writes.sh` hook
also fires on every research/design file write, feeding violations back to
the writing agent before the orchestrator gates run.

## /vault-secrets-implement (Phases 3–4)

```mermaid
flowchart TD
    A[validate-env.sh gate] --> B[resolve FEATURE · verify design.md Approved]
    B --> C(["vault-secrets-test-writer (haiku)<br/>scaffold + ALL test files"])
    C --> D[RED BASELINE GATE:<br/>build+vet PASS · tests FAIL not compile-error]
    D -->|broken once| C
    D --> E[plan dispatch waves from<br/>§6 files: / depends-on:]
    E --> F(["wave N: vault-secrets-developer (sonnet)<br/>batched items; concurrent only when independent"])
    F --> G[WAVE GATE: gofmt/build/vet · items checked off]
    G -->|more waves| F
    G --> H{go test ./... green?}
    H -->|failures, max 3 rounds| I(["developer (sonnet) targeted fix<br/>OR test-writer (haiku) if test contradicts design"])
    I --> H
    H -->|green| J(["vault-secrets-reviewer (sonnet)<br/>absence + logic sweep, fixes directly"])
    J --> K[Glob: review report · tests still green]
    K --> L(["vault-secrets-validator (sonnet)<br/>full pipeline + judge-criteria scoring"])
    L --> M{report PASS / score ≥ 8?}
    M -->|no, max 3 rounds| N(["developer (sonnet) at specific issues"])
    N --> L
    M -->|yes| O[checkpoint · push · PR with semver label<br/>skip in GitHub degradation mode]
```

Notes: the `SubagentStop` hook `gate-subagent-go.sh` blocks any developer /
test-writer / reviewer instance from finishing while gofmt/build/vet are
broken — failures feed back into the same instance's context instead of
costing a fresh dispatch. `go test` stays orchestrator-level because
expectations are phase-dependent (red baseline requires failing tests).

## evals/e2e run (wraps both workflows headlessly)

```mermaid
flowchart TD
    A[run-eval.sh: throwaway git workdir<br/>no remote · signing off] --> B["adapter: claude -p vault-secrets-e2e<br/>--plugin-dir · VAULT_E2E_EVAL=1"]
    B --> C(["headless session: /vault-secrets-plan flow<br/>Test Defaults answer all questions<br/>design auto-approved"])
    C --> D(["same session: /vault-secrets-implement flow<br/>all subagent dispatches as above"])
    D --> E[STOP GATE hook: session may not stop<br/>until validation report exists]
    E --> F[harvest artifacts: specs, .go, git log/diff]
    F --> G[deterministic.sh: 10 checks<br/>design/checklist/leak/reports/go pipeline]
    G --> H(["vault-e2e-judge (sonnet)<br/>fresh read-only session, 6-dimension rubric,<br/>forbidden from run's own reports"])
    H --> I["report.json / report.md<br/>grade = status ∧ checks ∧ judge ≥ 7.0<br/>cost · wall time · tokens by model"]
```

## /vault-db-plan and /vault-db-implement (database plugins)

The database workflow pair has the same dispatch topology as the two secrets
flows above, with these substitutions:

| Secrets flow node | Database flow node |
|---|---|
| taxonomy scan `vault-domain-category` | `vault-db-domain-category` |
| clarifications: credential model, security defaults, module org, integration env | credential features & types, statements contract, security defaults, module org, integration env |
| research slots: target-api, sdk-patterns, plugin-precedent, lifecycle-edge-cases, local-deployment | target-admin-api, sdk-dbplugin-patterns, plugin-precedent, lifecycle-edge-cases, local-deployment |
| `vault-secrets-design` (opus) | `vault-db-design` (opus) — H1 `# Database Plugin Design:` |
| compliance gate closed list `vault-plugin-*` | `vault-dbplugin-connection / -users / -rotation / -integration-testing` |
| `vault-secrets-test-writer` (haiku): backend shell + path tests via HandleRequest | `vault-db-test-writer` (haiku): struct with stubbed `Database` methods + direct-method tests |
| `vault-secrets-developer` (sonnet) per §6 item | `vault-db-developer` (sonnet) per §6 item |
| `vault-secrets-reviewer` (sonnet): bootstrap, client identity, WAL, leases | `vault-db-reviewer` (sonnet): sanitizer coverage, root self-rotation, rollback, idempotent delete |
| `vault-secrets-validator` (sonnet): smoke = mount + config + creds | `vault-db-validator` (sonnet): smoke = catalog register + `secrets enable database` + config write |

Hooks are shared and workflow-agnostic: `gate-spec-writes.sh` accepts both
closed skill lists, `gate-subagent-go.sh` fires on any `hashicorp/vault/sdk`
module, and `gate-eval-stop.sh` keys on `specs/*/design.md` regardless of
H1. The eval harness picks `/vault-db-e2e` when the case directory contains
a `workflow` file reading `db`, and the deterministic design check selects
the DB header set (`## 2. Target System Integration`, `## 3. Plugin
Interface Contract`) from the H1.
