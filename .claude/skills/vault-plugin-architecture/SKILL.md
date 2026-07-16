---
name: vault-plugin-architecture
description: Vault secrets engine backend architecture patterns — factory and backend struct, path registration, client seam, storage entries, framework.Secret leases, WAL crash safety, Rotation Manager integration (disabled by default), and the plugin entry point. Use when scaffolding or implementing secrets engine Go code.
user-invocable: false
---

# Vault Secrets Engine Architecture Patterns

Patterns for `framework.Backend`-based secrets engines on the public
`github.com/hashicorp/vault/sdk`. Precedent: public `vault-plugin-secrets-*`
repos (openldap, terraform). The constitution defines what is mandatory; this
skill shows how.

## Backend & Factory

```go
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
            pathConfig(&b),
            pathRoles(&b),
            pathCredentials(&b),
        ),
        Secrets:     []*framework.Secret{b.exampleToken()},
        BackendType: logical.TypeLogical,
        Invalidate:  b.invalidate,
    }
    return &b
}
```

- `Invalidate` on the `config` key resets the cached client (`b.reset()`),
  so config changes on other nodes take effect.
- `PathsSpecial.SealWrapStorage` lists every secret-bearing storage path from
  design §5. `framework.WALPrefix` is always `LocalStorage`.

## Cached Client (read-lock upgrade)

```go
func (b *exampleBackend) getClient(ctx context.Context, s logical.Storage) (Client, error) {
    b.lock.RLock()
    unlock := b.lock.RUnlock
    defer func() { unlock() }()
    if b.client != nil {
        return b.client, nil
    }
    b.lock.RUnlock()
    b.lock.Lock()
    unlock = b.lock.Unlock
    if b.client != nil { // re-check under write lock
        return b.client, nil
    }
    config, err := getConfig(ctx, s) // nil config → actionable error or defaults
    ...
}
```

Path handlers call `b.getClient(...)` and methods on the `Client` interface —
never HTTP/SDK calls directly. Tests replace the client with a fake at the
same seam (exported setter or struct field injection in `getTestBackend`).

## Path Definitions

- One path family per `path_*.go` file: a `pathXxx(b *backend) []*framework.Path`
  builder returning the `framework.Path` entries, plus the handlers.
- Every path: `Fields` with `Type`/`Description`/`Required`, per-operation
  `framework.PathOperation` with `Callback`, `HelpSynopsis`, `HelpDescription`,
  and `DisplayAttrs` using one engine-wide `operationPrefix<Engine>` constant.
- Name/list pairs: `roles/` + `roles/(?P<name>.+)` with `ExistenceCheck` on
  the named path for Create-vs-Update semantics.
- **Hierarchical layouts** (child under parent, e.g. accounts under hosts):
  child paths carry the full parent prefix
  (`hosts/(?P<host>[^/]+)/accounts/(?P<name>[^/]+)`); list operations exist at
  both levels; handlers resolve the parent entry first and fail with
  `logical.ErrorResponse` if it does not exist. Nest at most one level.

## Storage

```go
entry, err := logical.StorageEntryJSON(rolePrefix+name, roleEntry{Version: 1, ...})
...
if entry == nil { return nil, nil } // missing entry is not an error
```

- Typed entry structs with a `Version int` field; reject unknown versions.
- Key constants: `configPath = "config"`, `rolePrefix = "roles/"`.
- Read helpers return `(nil, nil)` for missing entries; callers translate to
  `logical.ErrorResponse` when the caller's input referenced it.

## Dynamic Credentials (framework.Secret)

```go
func (b *exampleBackend) exampleToken() *framework.Secret {
    return &framework.Secret{
        Type:   exampleTokenType,
        Fields: map[string]*framework.FieldSchema{...},
        Renew:  b.tokenRenew,
        Revoke: b.tokenRevoke,
    }
}
```

- `creds/<name>` handlers build the response via `b.Secret(type).Response(data, internalData)`
  and set `resp.Secret.TTL`/`MaxTTL` from role → mount resolution.
- `internalData` must carry everything Revoke needs (external IDs) — revoke
  MUST NOT depend on the role still existing, and MUST succeed if the external
  credential is already gone.

## Rotation & WAL

Ordering for any external mutation (rotate, create-then-store):

1. `framework.PutWAL(ctx, s, walKind, walEntry)` — intent, with external IDs
   and a `CreatedAt` timestamp
2. External call
3. Persist storage
4. `framework.DeleteWAL`

`WALRollback` (or an `InitializeFunc` tidy pass) reconciles incomplete
rotations on startup: list WALs, verify external state, repair or retry.
Never persist a credential that was not set externally; never lose track of
one that was.

## Rotation Manager (Enterprise, disabled by default)

Public SDK helpers integrate with Vault Enterprise's Rotation Manager; on OSS
the feature stays off and manual rotation endpoints work identically.

- Embed `automatedrotationutil.AutomatedRotationParams` in the config entry;
  call `automatedrotationutil.AddAutomatedRotationFields(fields)` on the
  config path and `config.ParseAutomatedRotationFields(data)` on write.
- On config write, register/deregister via `rotation.RotationJobConfigureRequest`
  / `rotation.RotationJobDeregisterRequest` through `b.System()` — only when
  the operator set a rotation schedule; the default is no registration.
- Set `RotateCredential` on the `framework.Backend` to the root-rotation
  function so the Rotation Manager can invoke it.
- Registration failures on OSS Vault (unsupported) must surface as actionable
  errors only when the user explicitly enabled automated rotation — never at
  plugin load.

## Entry Point (`cmd/vault-plugin-secrets-<name>/main.go`)

```go
func main() {
    apiClientMeta := &api.PluginAPIClientMeta{}
    flags := apiClientMeta.FlagSet()
    if err := flags.Parse(os.Args[1:]); err != nil { ... }
    tlsProviderFunc := api.VaultPluginTLSProvider(apiClientMeta.GetTLSConfig())
    err := plugin.ServeMultiplex(&plugin.ServeOpts{
        BackendFactoryFunc: example.Factory,
        TLSProviderFunc:    tlsProviderFunc,
    })
    ...
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
