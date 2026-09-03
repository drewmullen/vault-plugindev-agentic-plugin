# E2E Workflow Eval Harness

Evaluates the vault-plugindev workflows **end-to-end**: each case runs a full
`/vault-secrets-plan → /vault-secrets-implement` cycle headlessly in a
throwaway local git workdir, applies deterministic checks against the
generated plugin repo, optionally grades quality with an **independent judge
agent**, and writes a `report.json` + `report.md` (wall time, cost, per-check
results, judge scores) — so workflow changes get before/after measurement.

Ported from the terraform-agentic-workflows e2e framework, adapted from
Terraform artifacts to Vault secrets-engine artifacts.

## Quick start

```bash
# $0 plumbing test — no agent, no API cost, full pipeline
evals/e2e/run-eval.sh --case grafana --adapter mock

# real run — METERED claude -p API cost for the workflow AND the judge;
# run deliberately, one case at a time
evals/e2e/run-eval.sh --case grafana --adapter claude-code

# options
evals/e2e/run-eval.sh --case grafana --adapter claude-code \
  --model claude-sonnet-4-5 --max-turns 300 --keep-workdir
```

Output lands in `evals/e2e/runs/<timestamp>-<case>/` (git-ignored).

## Cost warning

`--adapter claude-code` runs are **metered API money** — a full
plan→implement cycle is a long multi-agent session, plus a second headless
session for the judge. Never script it in a loop casually; `--adapter mock`
exercises every other part of the pipeline for $0. Set `JUDGE_MODEL` to keep
the judge on a cheap model, `EVAL_TIMEOUT_SECS` to bound the run (default
5400s).

## How a case runs

```
cases/<name>/prompt.md ──► throwaway workdir (mktemp; git init + seed commit;
                           NO GitHub remote → workflows' degradation mode
                           skips issue/PR steps)
                       ──► adapter runs `/vault-secrets-e2e <prompt>` headlessly
                       ──► harvest: specs/, *.go, go.mod, git log + diff
                            → runs/<ts>-<case>/artifacts/
                       ──► checks/deterministic.sh (see below)
                       ──► judge (claude-code adapter only; fresh context,
                            read-only, vault-judge-criteria rubric)
                       ──► report.json + report.md
                       ──► workdir deleted (unless --keep-workdir)
```

**Grade**: `pass` ⇔ agent run finished ∧ all deterministic checks pass ∧
(mock adapter, or judge overall ≥ `JUDGE_MIN_SCORE` [default 7.0] with no
security override).

## How the plugin loads headlessly

The claude-code adapter passes the plugin repo root to
**`claude --plugin-dir <repo>`**, which loads the vault-plugindev skills,
agents, and hooks for that session only and resolves `${CLAUDE_PLUGIN_ROOT}`
inside the skills to the repo — no copying into the workdir, no marketplace
install needed. The case prompt file is copied into the workdir
(`eval-prompt.md`) so the plugin's out-of-tree file-access hook allows the
skill to read it; the prompt sent is `/vault-secrets-e2e eval-prompt.md`.

## Baseline comparison (no-skills ablation)

To measure the lift the plugin actually provides, run the same case through a
**stock Claude Code session with no plugin loaded** and diff it against a
skills run. The only difference between the two is `--plugin-dir` — same
model, same requirements, same judge — so the delta isolates the plugin.

```bash
# one command: runs BOTH adapters for a case, same model, writes the diff.
# METERED — two workflow sessions + two judge sessions. Pin --model.
evals/e2e/compare-case.sh --case grafana --model claude-sonnet-4-5

# already have a skills run for this case? reuse it, run only the baseline:
evals/e2e/compare-case.sh --case grafana --model claude-sonnet-4-5 --skip-skills

# diff any two existing run dirs after the fact ($0 — reads report.json only):
evals/e2e/compare-runs.sh runs/<skills-run> runs/<baseline-run>
```

`compare-case.sh` writes `runs/<ts>-<case>-compare/comparison.md`; each
underlying run keeps its own full run dir. `compare-runs.sh` **warns** (never
aborts) if the two runs are different cases or different models — either makes
the delta mean something other than "the plugin".

How the baseline differs from the skills run:

| | `--adapter claude-code` (skills) | `--adapter claude-baseline` (stock) |
|---|---|---|
| Plugin | `--plugin-dir <repo>` — skills, agents, hooks | **none** |
| Prompt | `/vault-secrets-e2e <file>` | the case's Engine Request + Test Defaults under a neutral "build this plugin here" preamble (derived from the same `prompt.md`) |
| Check profile | `full` (all gates) | `code` (workflow-artifact gates → SKIP; only gofmt/build/vet/test gate) |
| Judge | yes | yes (same independent judge) |

**The comparison axis is judge scores + code gates, not `grade`.** A stock
session produces a working plugin but not the SDD design/checklist/report
artifacts, so those checks are SKIP for a baseline by design — gating on them
would be an uninformative FAIL. Both sides still get the same judge, so
`judge.overall` and the six dimensions are the honest quality delta.

## Deterministic checks

`checks/deterministic.sh --workdir D --out checks.json [--profile full|code]`
re-runs real tools in the workdir (no transcript trust) and exits nonzero on
any FAIL. `--profile code` records the seven workflow-artifact checks as SKIP
and gates only on the four code checks (used for baseline runs):

| Check | Asserts |
|---|---|
| `design_doc` | exactly one `specs/*/design.md` with all 7 section headers |
| `checklist_complete` | every design §6 checklist item is `[x]` |
| `checklist_depends_on` | every §6 item declares `depends-on:` |
| `checklist_skills` | every §6 item declares `skills:` with values from the closed activity-skill list (or `—`) |
| `leak_check` | clean-room: no precedent-repo mentions (`openldap`, `secrets-terraform`, `vault-plugin-secrets-gcp`, `vault-plugin-secrets-aap`, `hashi-demo-lab`) in design.md; in `research-*.md` only on/after each file's `### Sources` line |
| `review_report` | `specs/*/reports/review_*.md` exists |
| `validation_report` | `specs/*/reports/validation_*.md` exists |
| `gofmt` | `gofmt -l` on the workdir is empty |
| `go_build` / `go_vet` / `go_test` | `go build/vet/test ./...` pass |

Requires `jq`, `git`, and an effective Go toolchain **>= 1.24** on PATH
(Go's automatic toolchain switching counts — a 1.21+ base `go` that can
satisfy a `go 1.24` module passes the probe).

## The independent judge

`judge/run-judge.sh` launches a **fresh headless session** following the
`.claude/agents/vault-e2e-judge.md` contract: read-only, forbidden from
reading the workflow's own review/validation reports (anchoring), scoring
the 6 `vault-judge-criteria` dimensions plus any per-case assertions from
`cases/<name>/assertions.md` (optional file, one `- assertion` per line).
It must reply with a single JSON verdict (one retry, then the report records
`judge_error`). The judge runs for every real agent adapter (`claude-code`
and `claude-baseline`); only the free `mock` adapter skips it.

## Runtime adapters

The runner never invokes an agent CLI directly. `adapters/<name>.sh`
implements:

```
adapters/<name>.sh run --prompt-file F --workdir D --out-dir O --timeout-secs N [--model M] [--max-turns K]
```

and writes a normalized `agent-result.json`. `claude-code.sh` is the real
runtime (raw envelope kept as `agent-envelope.json`); `claude-baseline.sh` is
the same runtime with **no `--plugin-dir`** and a derived vanilla prompt (the
no-skills ablation — see Baseline comparison above); `mock.sh` fabricates a
passing run for free pipeline tests:

- `MOCK_FAIL=1 evals/e2e/run-eval.sh ...` — the mock agent dies without
  artifacts (exercises failure reporting; run grades `fail`)
- `MOCK_SLEEP_SECS=N` — simulate wall time

To evaluate another agent CLI, add an adapter — nothing else changes.

## Layout of `runs/` output

```
runs/<timestamp>-<case>/
├── prompt.md            # the case prompt as sent
├── agent-result.json    # normalized adapter result (status, cost, turns)
├── agent-envelope.json  # raw claude JSON envelope (claude-code only)
├── agent-stderr.log     # claude stderr (claude-code only)
├── artifacts/           # harvested from the workdir
│   ├── specs/           # design.md, clarifications, research, reports
│   ├── *.go, go.mod     # the generated plugin
│   ├── git-log.txt
│   └── git-diff.patch   # seed commit → HEAD
├── checks.json          # deterministic gate outcomes
├── checks.log           # per-check PASS/FAIL lines
├── judge-prompt.md      # rendered judge prompt (claude-code only)
├── judge-envelope.json  # raw judge session envelope
├── judge-verdict.json   # validated verdict (null if skipped/failed)
├── judge-result.json    # judge cost/duration or judge_error
├── report.json          # everything, machine-readable
└── report.md            # human summary
```

## Adding a case

Create `cases/<name>/prompt.md`: the engine request plus a **Test Defaults**
block answering every clarify question (credential model, security defaults,
Go module org, integration environment — keep it fakes-only so runs never
need live systems). Optional `cases/<name>/assertions.md` adds per-case judge
assertions. Style-match `cases/grafana/prompt.md`.
