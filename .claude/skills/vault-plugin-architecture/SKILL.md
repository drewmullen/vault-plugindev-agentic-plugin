---
name: vault-plugin-architecture
description: Vault secrets engine core architecture — factory and backend struct, framework.Backend wiring (paths, secrets, WAL rollback, Rotation Manager hook), path registration conventions, hierarchical layouts, plugin entry point, and repo scaffold. Activity-specific patterns (config/client, roles, creds, static roles) live in the vault-plugin-* activity skills. Use when scaffolding backend.go, main.go, or wiring a new path family.
user-invocable: false
---

# Vault Secrets Engine Architecture Patterns

Core scaffold patterns for `framework.Backend`-based secrets engines on the
public `github.com/hashicorp/vault/sdk`. The constitution defines what is
mandatory; this skill shows how the skeleton fits together. The per-activity
code lives in dedicated skills — see the activity map at the end.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-*` repos, local
checkouts). Web research is for the *target system's* API only. The examples
use a generic `example` engine; substitute the engine's own names, fields,
and client operations from design §2/§3.

## Backend & Factory

```go
const operationPrefixExample = "example"

func Factory(ctx context.Context, conf *logical.BackendConfig) (logical.Backend, error) {
    b := backend()
    if err := b.Setup(ctx, conf); err != nil {
        return nil, err
    }
    return b, nil
}

type exampleBackend struct {
    *framework.Backend
    lock   sync.RWMutex
    client Client // narrow interface — the ONLY seam to the external system
}

func backend() *exampleBackend {
    b := exampleBackend{}
    b.Backend = &framework.Backend{
        Help: strings.TrimSpace(backendHelp),
        PathsSpecial: &logical.Paths{
            LocalStorage:    []string{framework.WALPrefix},
            SealWrapStorage: []string{configPath, rolePrefix + "*"},
        },
        Paths: framework.PathAppend(
            pathRoles(&b),
            []*framework.Path{
                pathConfig(&b),
                pathCredentials(&b),
            },
        ),
        Secrets:           []*framework.Secret{b.exampleToken()},
        BackendType:       logical.TypeLogical,
        Invalidate:        b.invalidate,
        WALRollback:       b.walRollback,
        WALRollbackMinAge: 5 * time.Minute,
        // Rotation Manager entry point (no-op unless the operator enables
        // automated rotation in config):
        RotateCredential: func(ctx context.Context, req *logical.Request) error {
            return b.rotateRootCredential(ctx, req)
        },
    }
    return &b
}

func (b *exampleBackend) reset() {
    b.lock.Lock()
    defer b.lock.Unlock()
    b.client = nil
}

func (b *exampleBackend) invalidate(_ context.Context, key string) {
    if key == configPath {
        b.reset() // config changed on another node — rebuild the client lazily
    }
}
```

- `PathsSpecial.SealWrapStorage` lists every secret-bearing storage path from
  design §5. `framework.WALPrefix` is always `LocalStorage`.
- `Paths` must register every path family design §3 declares — a builder per
  `path_*.go` file, composed with `framework.PathAppend`. When patterns can
  shadow each other (a generic name regex swallowing a more specific
  sub-path), register the most-specific paths first.
- The bodies of `getClient` (double-checked read-lock upgrade),
  `rotateRootCredential`, and `walRollback` are in
  `vault-plugin-config-client` and `vault-plugin-dynamic-creds`.
- Engines with static roles add a rotation queue, stripe locks, and
  `InitializeFunc`/`Clean` hooks to this struct and literal — see
  `vault-plugin-static-roles`.

## Path Registration Conventions

- One path family per `path_*.go` file: a builder returning the
  `framework.Path` entries plus the handlers and storage helpers, with its
  `_test.go` sibling.
- Every path sets `DisplayAttrs` (`OperationPrefix` = the engine's constant;
  verb/suffix per operation) and `HelpSynopsis`/`HelpDescription`.
- Validation rules (`logical.ErrorResponse` + nil error for user mistakes)
  belong in write handlers, before anything persists.

### Hierarchical layouts (child under parent)

Child paths carry the full parent prefix, composed with
`framework.GenericNameRegex` per captured segment; both segments arrive as
`framework.FieldData`:

```go
Pattern: "orgs/" + framework.GenericNameRegex("org") + "/roles/" + framework.GenericNameRegex("name"),
```

- Storage keys mirror the path hierarchy (`roles/<org>/<name>`) so list
  operations map to `req.Storage.List(prefix)`.
- List paths exist at both levels (`orgs/?$` and `orgs/<org>/roles/?$`).
- Handlers resolve the parent entry first and fail with
  `logical.ErrorResponse` if it does not exist. Nest at most one level.

## Known SDK Gotchas

1. A `framework.Path` that registers `logical.CreateOperation` but has no
   `ExistenceCheck` panics at backend initialization — singleton paths like
   `config` included. Every path with a create operation wires one.
2. Rotation-config gotchas (`automatedrotationutil` field pairing and type
   collisions) are listed in `vault-plugin-config-client`.

## Entry Point (`cmd/vault-plugin-secrets-<name>/main.go`)

```go
func main() {
    apiClientMeta := &api.PluginAPIClientMeta{}
    flags := apiClientMeta.FlagSet()
    if err := flags.Parse(os.Args[1:]); err != nil {
        log.Fatal(err)
    }
    tlsProviderFunc := api.VaultPluginTLSProvider(apiClientMeta.GetTLSConfig())
    err := plugin.ServeMultiplex(&plugin.ServeOpts{
        BackendFactoryFunc: example.Factory,
        TLSProviderFunc:    tlsProviderFunc,
    })
    if err != nil {
        log.Fatal(err)
    }
}
```

## Repo Scaffold

- `go.mod`: module `github.com/{org}/vault-plugin-secrets-{name}`, Go >= 1.24,
  deps per constitution §5, no `replace` directives.
- `Makefile`: `build` (CGO_ENABLED=0 into `bin/`), `test` (`go test -race ./...`),
  `fmt` (`gofmt -w .`), `vet`, and a `dev` target that copies the binary into a
  `vault server -dev -dev-plugin-dir` directory.
- `README.md`: mount/configure/use walkthrough plus the root-credential
  least-privilege scopes from design §5.

## Activity Skill Map

Each design §6 checklist item names the activity skill(s) it needs; load
them before implementing that item's files.

| Activity | Files | Skill |
|---|---|---|
| Config, client seam, root rotation | `path_config.go`, `client.go`, `path_config_rotate_root.go` | `vault-plugin-config-client` |
| Dynamic role CRUD | `path_roles.go` | `vault-plugin-dynamic-roles` |
| Dynamic credentials + lease + mint WAL | `path_creds.go`, `secret_*.go`, `wal.go` | `vault-plugin-dynamic-creds` |
| Static roles + rotation queue + static creds | `path_static_roles.go`, `rotation.go`, `path_static_creds.go` | `vault-plugin-static-roles` |
| Integration harness | `docker-compose.yml`, acceptance tests | `vault-plugin-integration-testing` |
