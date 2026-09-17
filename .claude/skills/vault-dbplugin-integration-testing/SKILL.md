---
name: vault-dbplugin-integration-testing
description: Opt-in live integration test patterns for generated database plugins — docker-compose target database container, bootstrap script (wait-for-healthy, root account provisioning, gitignored integration.env), env-gated Go acceptance tests (VAULT_ACC=1) calling the plugin's methods against the live target, full e2e via vault server -dev with the plugin registered in the database catalog and driven through database/config, roles, creds, static-roles, rotate-root, and unconditional teardown. Use when scaffolding or running the harness a design's Integration Test Environment subsection opts into.
user-invocable: false
---

# Vault Database Plugin Integration Test Patterns

Two live layers, both opt-in per the design's §2 "Integration Test
Environment" subsection and both degradable — no docker/podman means
WARN-and-skip, never a failure:

- **L1 — acceptance tests**: env-gated Go tests (`VAULT_ACC=1`) call the
  PLUGIN's own methods (`Initialize`/`NewUser`/`UpdateUser`/`DeleteUser`)
  with the production client against the containerized target. This
  catches admin-API drift that fakes mirror back.
- **L2 — dev-server e2e**: build the plugin binary, register it in the
  `database` catalog of `vault server -dev`, and drive
  `database/config` → `roles` → `creds` → revoke → `rotate-root` →
  `static-roles` → `rotate-role` through the Vault CLI, verifying state in
  the target after each step.

**This skill is self-contained.** Scaffold and run from the patterns below —
do NOT read or fetch other plugin codebases. The examples use a generic
`example` target; substitute the image, ports, admin commands, and
credential mechanics from the design's §2 subsection and the
`local-deployment` research file.

Unit tests remain fakes-only per `vault-dbplugin-testing`; this harness is
additive and never replaces them.

## `docker-compose.test.yml`

```yaml
services:
  target:
    image: example/example-db:16.2       # pin from design §2 — never :latest
    ports:
      - "5432"                           # container port only — host port assigned by compose
    environment:
      EXAMPLE_ROOT_USER: vault-root      # throwaway container-local root creds
      EXAMPLE_ROOT_PASSWORD: vault-root-pw
    healthcheck:
      test: ["CMD-SHELL", "example-cli ping -u vault-root -p vault-root-pw"]
      interval: 5s
      timeout: 3s
      retries: 30
```

Rules:

- Exactly one target container; a sidecar only if the image cannot run
  without one (say so in design §2).
- Image tag from the design, matching the researched tier.
- Root credentials are container-local throwaways baked into the compose
  file — never user-supplied, worthless outside the container.

## Bootstrap script — `scripts/integration-bootstrap.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
COMPOSE_FILE="docker-compose.test.yml"

PORT="$(docker compose -f "$COMPOSE_FILE" port target 5432 | cut -d: -f2)"
TARGET_URL="example://localhost:${PORT}"

DEADLINE=$((SECONDS + 120))
until [ "$(docker compose -f "$COMPOSE_FILE" ps --format json target | grep -c '"Health":"healthy"')" -ge 1 ]; do
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "ERROR: target not healthy within 120s" >&2
        docker compose -f "$COMPOSE_FILE" logs target >&2
        exit 1
    fi
    sleep 2
done

# Provision the least-privilege root account the plugin will use (design §5),
# distinct from the container superuser, using the container's default creds.
docker compose -f "$COMPOSE_FILE" exec -T target example-cli -u vault-root -p vault-root-pw \
    "CREATE USER vault WITH PASSWORD 'vault-acc' CREATEROLE"   # substitute the design's grants

cat > integration.env <<EOF
TARGET_URL=${TARGET_URL}
TARGET_USERNAME=vault
TARGET_PASSWORD=vault-acc
EOF
echo "integration.env written (${TARGET_URL})"
```

Rules: bounded wait that dumps logs on timeout; programmatic provisioning
only; `integration.env` is the ONLY handoff and MUST be gitignored.

## L1 — Env-gated acceptance tests (`acceptance_test.go`)

```go
func testAccPreCheck(t *testing.T) map[string]interface{} {
    t.Helper()
    if os.Getenv("VAULT_ACC") != "1" {
        t.Skip("acceptance test: set VAULT_ACC=1 to run (requires make integration-up)")
    }
    for _, k := range []string{"TARGET_URL", "TARGET_USERNAME", "TARGET_PASSWORD"} {
        if os.Getenv(k) == "" {
            t.Fatalf("%s unset — run scripts/integration-bootstrap.sh and source integration.env", k)
        }
    }
    return map[string]interface{}{
        "connection_url": os.Getenv("TARGET_URL"),
        "username":       os.Getenv("TARGET_USERNAME"),
        "password":       os.Getenv("TARGET_PASSWORD"),
    }
}

func TestAccUserLifecycle(t *testing.T) {
    cfg := testAccPreCheck(t)
    raw, err := New() // PRODUCTION factory — sanitizer and real client included
    require.NoError(t, err)
    db := raw.(dbplugin.Database)
    t.Cleanup(func() { _ = db.Close() })

    dbtesting.AssertInitialize(t, db, dbplugin.InitializeRequest{Config: cfg, VerifyConnection: true})

    resp := dbtesting.AssertNewUser(t, db, dbplugin.NewUserRequest{
        UsernameConfig: dbplugin.UsernameMetadata{DisplayName: "acc", RoleName: "reader"},
        Statements:     dbplugin.Statements{Commands: []string{`{"roles":["reader"]}`}}, // design §3 format
        CredentialType: dbplugin.CredentialTypePassword,
        Password:       "Acc-pass-1-" + t.Name(),
        Expiration:     time.Now().Add(time.Hour),
    })
    t.Cleanup(func() { _, _ = db.DeleteUser(context.Background(), dbplugin.DeleteUserRequest{Username: resp.Username}) })

    // Verify in the TARGET, not just the response: log in as the new user.
    require.NoError(t, loginAs(t, cfg, resp.Username, "Acc-pass-1-"+t.Name()))

    dbtesting.AssertUpdateUser(t, db, dbplugin.UpdateUserRequest{
        Username: resp.Username,
        Password: &dbplugin.ChangePassword{NewPassword: "Acc-pass-2-" + t.Name()},
    })
    require.Error(t, loginAs(t, cfg, resp.Username, "Acc-pass-1-"+t.Name()))
    require.NoError(t, loginAs(t, cfg, resp.Username, "Acc-pass-2-"+t.Name()))

    dbtesting.AssertDeleteUser(t, db, dbplugin.DeleteUserRequest{Username: resp.Username})
    dbtesting.AssertDeleteUser(t, db, dbplugin.DeleteUserRequest{Username: resp.Username}) // idempotent
    require.Error(t, loginAs(t, cfg, resp.Username, "Acc-pass-2-"+t.Name()))
}
```

Rules:

- The subject is the production plugin built by `New()` — never the fake.
- `dbtesting` (`sdk/database/dbplugin/v5/testing`) assertion helpers are
  the SDK's own; use them for the happy path and plain calls for expected
  failures.
- Table cases mirror exactly the §3/§4 rows marked `live?: yes`.
- Every test provisions and cleans up its own users via `t.Cleanup`;
  order-independent, re-runnable.
- Root self-rotation live test: create a dedicated root-like account in
  bootstrap for it (rotating the shared `vault` account would break the
  other tests); assert the old password fails and the new one works, then
  rotate back in cleanup.

## L2 — Dev-server e2e

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN=vault-plugin-database-example
PLUGIN_DIR="$(mktemp -d)"
export VAULT_ADDR='http://127.0.0.1:8200' VAULT_TOKEN=root

go build -o "${PLUGIN_DIR}/${PLUGIN}" ./cmd/${PLUGIN}
vault server -dev -dev-root-token-id root -dev-plugin-dir="${PLUGIN_DIR}" > vault-dev.log 2>&1 &
VAULT_PID=$!
trap 'kill "$VAULT_PID" 2>/dev/null || true; rm -rf "$PLUGIN_DIR"' EXIT
for _ in $(seq 1 30); do vault status >/dev/null 2>&1 && break; sleep 1; done

SHA256="$(shasum -a 256 "${PLUGIN_DIR}/${PLUGIN}" | cut -d' ' -f1)"
vault plugin register -sha256="$SHA256" database "$PLUGIN"
vault secrets enable database

# config: plugin fields come from design §3 Config Fields
vault write database/config/example plugin_name="$PLUGIN" allowed_roles='*' \
    connection_url="$TARGET_URL" username="$TARGET_USERNAME" password="$TARGET_PASSWORD"

# dynamic role → creds → verify in target → revoke → verify gone
vault write database/roles/reader db_name=example default_ttl=5m max_ttl=1h \
    creation_statements='{"roles":["reader"]}'
USER="$(vault read -field=username database/creds/reader)"
# ...login as $USER against the target succeeds...
vault lease revoke -prefix database/creds/reader
# ...login as $USER now fails...

# rotate-root → the plugin must still work afterwards
vault write -f database/rotate-root/example
vault read database/creds/reader >/dev/null

# static role → static-creds → rotate-role → verify new password works
vault write database/static-roles/svc db_name=example username=svc-account rotation_period=1h
vault read -field=password database/static-creds/svc
vault write -f database/rotate-role/svc
```

Rules:

- `VAULT_TOKEN=root` in the environment — NEVER `vault login`.
- After every mutating step, verify in the TARGET — that check is the point.
- The trap kills the dev server and removes the temp plugin dir no matter
  how the script exits.
- `rotate-root` in L2 changes the password of the account in
  `integration.env` — run it last, or provision a dedicated account for it.

## Teardown discipline & Makefile

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

`docker compose … down -v` always runs; use `podman compose` transparently
when only podman exists — detection belongs to the caller
(validator / validate-env.sh), not the generated files.

## Tier discipline & Safety

- Scenarios needing features the runnable tier lacks are never `live?: yes`.
- `integration.env` is gitignored — verify before every checkpoint.
- The harness targets THROWAWAY containers. A user-supplied endpoint that
  could be production (non-localhost, real domain, real credentials) is a
  stop-and-ask before anything runs against it. Acceptance tests create and
  drop real users — acceptable only because the target is disposable.
