---
name: vault-plugin-integration-testing
description: Opt-in live integration test patterns for generated secrets engines — docker-compose target container, bootstrap script (wait-for-healthy, token provisioning, gitignored integration.env), env-gated Go acceptance tests (VAULT_ACC=1) running the production client, full e2e via vault server -dev with -dev-plugin-dir, and unconditional teardown discipline. Use when scaffolding or running the integration harness a design's Integration Test Environment subsection opts into.
user-invocable: false
---

# Vault Secrets Engine Integration Test Patterns

Two live layers, both opt-in per the design's §2 "Integration Test
Environment" subsection and both degradable — no docker/podman means
WARN-and-skip, never a failure:

- **L1 — acceptance tests**: env-gated Go tests (`VAULT_ACC=1`) run the
  PRODUCTION `Client` against the containerized target system. This catches
  API-contract drift that fakes mirror back (a fake asserts what we *believe*
  the API does; L1 asserts what it *actually* does).
- **L2 — dev-server e2e**: build the plugin binary, register it in
  `vault server -dev -dev-plugin-dir`, drive config→roles→creds→revoke via
  the Vault API/CLI, and verify actual state in the target system after each
  step.

**This skill is self-contained.** Scaffold and run from the patterns below —
do NOT read or fetch other plugin codebases. The examples use a generic
`example` target system; substitute the image, ports, endpoints, and token
mechanics from the design's §2 subsection and the `local-deployment`
research file.

Unit tests remain fakes-only per `vault-plugin-testing`; this harness is
additive and never replaces them.

## `docker-compose.test.yml`

One service: the target system, image+tag exactly as pinned in design §2.
Let compose assign the host port (avoid collisions with anything already
running); the bootstrap script resolves the actual port. Always include a
healthcheck so "up" means "serving".

```yaml
services:
  target:
    image: example/example-server:11.2.0   # pin from design §2 — never :latest
    ports:
      - "3000"                             # container port only — host port assigned by compose
    environment:
      EXAMPLE_ADMIN_USER: admin            # throwaway container-local creds
      EXAMPLE_ADMIN_PASSWORD: admin
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000/api/health"]
      interval: 5s
      timeout: 3s
      retries: 30
```

Rules:

- Exactly one target-service container; the harness is not a general
  orchestration layer. Add a sidecar only if the target image cannot run
  without one (e.g. a required database) — and say so in design §2.
- Image tag comes from the design and matches the tier researched (OSS vs
  Enterprise features differ — see "Tier discipline" below).
- Default admin credentials are container-local throwaways baked into the
  compose file. They never come from the user and are worthless outside the
  container.

## Bootstrap script — `scripts/integration-bootstrap.sh`

Runs after `docker compose up -d`; produces a gitignored `integration.env`
that the tests source. Shape:

```bash
#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.test.yml"

# 1. Resolve the compose-assigned host port
PORT="$(docker compose -f "$COMPOSE_FILE" port target 3000 | cut -d: -f2)"
TARGET_URL="http://localhost:${PORT}"

# 2. Wait for healthy (compose healthcheck), bounded
DEADLINE=$((SECONDS + 120))
until [ "$(docker compose -f "$COMPOSE_FILE" ps --format json target | grep -c '"Health":"healthy"')" -ge 1 ]; do
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "ERROR: target not healthy within 120s" >&2
        docker compose -f "$COMPOSE_FILE" logs target >&2
        exit 1
    fi
    sleep 2
done

# 3. Provision an admin API token programmatically (default container creds)
#    — substitute the target's real token endpoint from design §2
TARGET_TOKEN="$(curl -sf -u admin:admin -X POST \
    -H 'Content-Type: application/json' \
    -d '{"name":"vault-acc-test","role":"Admin"}' \
    "${TARGET_URL}/api/auth/keys" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')"

if [ -z "$TARGET_TOKEN" ]; then
    echo "ERROR: token provisioning failed" >&2
    exit 1
fi

# 4. Write the env file the acceptance tests consume (gitignored)
cat > integration.env <<EOF
TARGET_URL=${TARGET_URL}
TARGET_TOKEN=${TARGET_TOKEN}
EOF
echo "integration.env written (${TARGET_URL})"
```

Rules:

- Wait loop is bounded and dumps container logs on timeout — a hung
  bootstrap must fail loudly, not stall the pipeline.
- Token provisioning is programmatic against the container's default admin
  credentials; no interactive step, no user-supplied secret.
- `integration.env` is the ONLY handoff to the tests and MUST be in
  `.gitignore` (the test-writer adds it). It contains a live token for a
  throwaway container — still never committed.

## L1 — Env-gated Go acceptance tests

`TestAcc`-prefixed functions in `acceptance_test.go` (or per-family
`*_acc_test.go`), guarded so the red baseline and every non-opted-in run
skip them:

```go
func testAccPreCheck(t *testing.T) (url, token string) {
    t.Helper()
    if os.Getenv("VAULT_ACC") != "1" {
        t.Skip("acceptance test: set VAULT_ACC=1 to run (requires make integration-up)")
    }
    url, token = os.Getenv("TARGET_URL"), os.Getenv("TARGET_TOKEN")
    if url == "" || token == "" {
        t.Fatal("TARGET_URL/TARGET_TOKEN unset — run scripts/integration-bootstrap.sh and source integration.env")
    }
    return url, token
}

func TestAccClient_TokenLifecycle(t *testing.T) {
    url, token := testAccPreCheck(t)
    c, err := NewClient(&ClientConfig{URL: url, Token: token}) // PRODUCTION client
    require.NoError(t, err)

    created, err := c.CreateToken(context.Background(), CreateTokenRequest{Name: "acc-test-tok"})
    require.NoError(t, err)
    t.Cleanup(func() { _ = c.DeleteToken(context.Background(), created.ID) })

    require.NoError(t, c.DeleteToken(context.Background(), created.ID))
    // Idempotency contract from design §2: second delete of a gone credential succeeds
    require.NoError(t, c.DeleteToken(context.Background(), created.ID))
}
```

Rules:

- The subject is the production `Client` — never the fake, never a second
  client written for tests. If the production client can't be constructed
  from URL+token alone, that is a design bug to surface, not to shim around.
- Table cases mirror exactly the §3/§4 scenario rows marked `live?: yes` in
  the design — same behavior, real API. No invented scenarios.
- Every test provisions its own external resources and cleans them up via
  `t.Cleanup` — tests are order-independent and re-runnable against the same
  container.
- Env vars come from `integration.env` (the Makefile sources it); tests read
  only `os.Getenv` — no file parsing in Go.

## L2 — Dev-server e2e

Full path: real plugin binary, real Vault, real target. Scripted shape
(run by the validator, or manually via a Makefile target):

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN=vault-plugin-secrets-example
PLUGIN_DIR="$(mktemp -d)"
export VAULT_ADDR='http://127.0.0.1:8200' VAULT_TOKEN=root

go build -o "${PLUGIN_DIR}/${PLUGIN}" ./cmd/${PLUGIN}

vault server -dev -dev-root-token-id root -dev-plugin-dir="${PLUGIN_DIR}" \
    > vault-dev.log 2>&1 &
VAULT_PID=$!
trap 'kill "$VAULT_PID" 2>/dev/null || true; rm -rf "$PLUGIN_DIR"' EXIT

for _ in $(seq 1 30); do vault status >/dev/null 2>&1 && break; sleep 1; done

SHA256="$(shasum -a 256 "${PLUGIN_DIR}/${PLUGIN}" | cut -d' ' -f1)"
vault plugin register -sha256="$SHA256" secret "$PLUGIN"
vault secrets enable -path=example "$PLUGIN"

# Drive the lifecycle — substitute the design's §3 paths and fields
vault write example/config url="$TARGET_URL" token="$TARGET_TOKEN"
vault write example/roles/e2e ttl=5m
CRED_ID="$(vault read -field=id example/creds/e2e)"
# ...verify the credential EXISTS in the target (curl its API with TARGET_TOKEN)...
vault lease revoke -prefix example/creds/e2e
# ...verify the credential is GONE from the target...
```

Rules:

- Authenticate with `VAULT_TOKEN=root` in the environment — NEVER
  `vault login` (guardrail-blocked, and it mutates `~/.vault-token`).
- After every mutating step, verify state in the TARGET system, not just
  Vault's response — that external check is the entire point of L2.
- The trap kills the dev server and removes the temp plugin dir no matter
  how the script exits. A leaked dev server poisons the next run.
- Rotation coverage where the design has it: rotate, then confirm the old
  secret no longer authenticates against the target and the new one does.

## Teardown discipline & Makefile

Teardown is unconditional — trap-based in scripts, `|| true`-free in intent:
`docker compose -f docker-compose.test.yml down -v` always runs (the `-v`
drops volumes so every run starts from a pristine target), and any started
`vault` dev server is killed, even when a prior step failed.

Generated Makefile targets:

```make
integration-up: ## start the target container and provision integration.env
	docker compose -f docker-compose.test.yml up -d
	bash scripts/integration-bootstrap.sh

integration-down: ## stop the target container and drop its volumes
	docker compose -f docker-compose.test.yml down -v

testacc: ## run env-gated acceptance tests against the live target
	@test -f integration.env || (echo "run 'make integration-up' first" && exit 1)
	set -a && . ./integration.env && set +a && \
		VAULT_ACC=1 go test -race -run 'TestAcc' -v ./...
```

Use `podman compose` transparently when `docker` is absent but `podman` is
present — detection belongs in the caller (validator / validate-env.sh),
not hardcoded in the generated files.

## Tier discipline

The runnable container tier (design §2 subsection) bounds what can be live:

- Scenarios needing endpoints/features the runnable tier lacks (e.g.
  Enterprise-only RBAC in an OSS image) are NEVER marked `live?: yes` — they
  stay fakes-only, and the design flags the conflict in §7.
- L1/L2 must not silently downgrade an assertion to fit the tier; either the
  scenario runs fully live or it is not live at all.

## Safety

- `integration.env` is gitignored — verify before every checkpoint.
- The harness targets THROWAWAY containers with baked-in default creds. If a
  user supplies a sandbox endpoint instead, treat any endpoint that could be
  production (non-localhost, real domain, real credentials) as a stop-and-ask:
  flag it to the user explicitly before running anything against it. Never
  run acceptance tests against an endpoint the user has not confirmed is
  disposable.
- Acceptance tests create and delete real resources in the target — that is
  acceptable ONLY because the target is disposable. The cleanup rules above
  are hygiene, not a safety boundary.
