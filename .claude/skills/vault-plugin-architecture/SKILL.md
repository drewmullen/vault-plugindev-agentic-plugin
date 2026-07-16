---
name: vault-plugin-architecture
description: Vault secrets engine backend architecture patterns — factory and backend struct, path registration, client seam, storage entries, framework.Secret leases, WAL crash safety, Rotation Manager integration (disabled by default), and the plugin entry point. Use when scaffolding or implementing secrets engine Go code.
user-invocable: false
---

# Vault Secrets Engine Architecture Patterns

Patterns for `framework.Backend`-based secrets engines on the public
`github.com/hashicorp/vault/sdk`. The constitution defines what is mandatory;
this skill shows how.

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

## Cached Client (read-lock upgrade)

```go
func (b *exampleBackend) getClient(ctx context.Context, s logical.Storage) (Client, error) {
    b.lock.RLock()
    unlockFunc := b.lock.RUnlock
    defer func() { unlockFunc() }()

    if b.client != nil {
        return b.client, nil
    }

    b.lock.RUnlock()
    b.lock.Lock()
    unlockFunc = b.lock.Unlock

    if b.client != nil { // re-check under write lock
        return b.client, nil
    }

    config, err := getConfig(ctx, s)
    if err != nil {
        return nil, err
    }
    if config == nil {
        return nil, errors.New("backend is not configured: write config first")
    }

    client, err := newClient(config)
    if err != nil {
        return nil, err
    }
    b.client = client
    return b.client, nil
}
```

Path handlers call `b.getClient(...)` and methods on the `Client` interface —
never HTTP/SDK calls directly. Tests replace the client with a fake at the
same seam (struct field injection in `getTestBackend`).

**Warning — `reset()` is not a rotation tool.** `reset()`/`invalidate` exist
ONLY for cross-node config changes (replication invalidation). A rotation or
config handler that changes the credential the client itself authenticates
with must swap it IN-PLACE on the live client via a narrow client method
(e.g. `Client.UpdateToken(newToken)`) — never call reset-and-rebuild from
inside a handler: it silently replaces the injected fake client in tests and
races with in-flight requests in production.

## Path Definitions

One path family per `path_*.go` file: a builder returning the
`framework.Path` entries plus the handlers and storage helpers.

```go
const rolePrefix = "roles/"

type roleEntry struct {
    Version int           `json:"version"` // start at 1; reject unknown versions on read
    Name    string        `json:"name"`
    TTL     time.Duration `json:"ttl"`
    MaxTTL  time.Duration `json:"max_ttl"`
}

// toResponseData controls exactly what a role read returns — never secrets.
func (r *roleEntry) toResponseData() map[string]interface{} {
    return map[string]interface{}{
        "name":    r.Name,
        "ttl":     r.TTL.Seconds(),
        "max_ttl": r.MaxTTL.Seconds(),
    }
}

func pathRoles(b *exampleBackend) []*framework.Path {
    return []*framework.Path{
        {
            Pattern: rolePrefix + framework.GenericNameRegex("name"),
            DisplayAttrs: &framework.DisplayAttributes{
                OperationPrefix: operationPrefixExample,
                OperationSuffix: "role",
            },
            Fields: map[string]*framework.FieldSchema{
                "name": {
                    Type:        framework.TypeLowerCaseString,
                    Description: "Name of the role",
                    Required:    true,
                },
                "ttl": {
                    Type:        framework.TypeDurationSecond,
                    Description: "Default lease for generated credentials. 0 uses system default.",
                },
                "max_ttl": {
                    Type:        framework.TypeDurationSecond,
                    Description: "Maximum lease time. 0 uses system default.",
                },
            },
            ExistenceCheck: b.pathRoleExistenceCheck,
            Operations: map[logical.Operation]framework.OperationHandler{
                logical.ReadOperation:   &framework.PathOperation{Callback: b.pathRolesRead},
                logical.CreateOperation: &framework.PathOperation{Callback: b.pathRolesWrite},
                logical.UpdateOperation: &framework.PathOperation{Callback: b.pathRolesWrite},
                logical.DeleteOperation: &framework.PathOperation{Callback: b.pathRolesDelete},
            },
            HelpSynopsis:    pathRoleHelpSynopsis,
            HelpDescription: pathRoleHelpDescription,
        },
        {
            Pattern: rolePrefix + "?$",
            DisplayAttrs: &framework.DisplayAttributes{
                OperationPrefix: operationPrefixExample,
                OperationVerb:   "list",
                OperationSuffix: "roles",
            },
            Operations: map[logical.Operation]framework.OperationHandler{
                logical.ListOperation: &framework.PathOperation{Callback: b.pathRolesList},
            },
            HelpSynopsis:    pathRoleListHelpSynopsis,
            HelpDescription: pathRoleListHelpDescription,
        },
    }
}

func (b *exampleBackend) pathRoleExistenceCheck(ctx context.Context, req *logical.Request, d *framework.FieldData) (bool, error) {
    out, err := req.Storage.Get(ctx, req.Path)
    if err != nil {
        return false, fmt.Errorf("existence check failed: %w", err)
    }
    return out != nil, nil
}

func (b *exampleBackend) pathRolesList(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
    entries, err := req.Storage.List(ctx, rolePrefix)
    if err != nil {
        return nil, err
    }
    return logical.ListResponse(entries), nil
}

func (b *exampleBackend) pathRolesRead(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    entry, err := getRole(ctx, req.Storage, d.Get("name").(string))
    if err != nil {
        return nil, err
    }
    if entry == nil {
        return nil, nil // missing entry on read is not an error
    }
    return &logical.Response{Data: entry.toResponseData()}, nil
}

func (b *exampleBackend) pathRolesWrite(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    name := d.Get("name").(string)
    if name == "" {
        return logical.ErrorResponse("missing role name"), nil
    }

    role, err := getRole(ctx, req.Storage, name)
    if err != nil {
        return nil, err
    }
    if role == nil {
        role = &roleEntry{Version: 1}
    }
    role.Name = name

    if ttlRaw, ok := d.GetOk("ttl"); ok {
        role.TTL = time.Duration(ttlRaw.(int)) * time.Second
    }
    if maxTTLRaw, ok := d.GetOk("max_ttl"); ok {
        role.MaxTTL = time.Duration(maxTTLRaw.(int)) * time.Second
    }
    if role.MaxTTL != 0 && role.TTL > role.MaxTTL {
        return logical.ErrorResponse("ttl cannot be greater than max_ttl"), nil
    }

    if err := setRole(ctx, req.Storage, name, role); err != nil {
        return nil, err
    }
    return nil, nil
}

func (b *exampleBackend) pathRolesDelete(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    if err := req.Storage.Delete(ctx, rolePrefix+d.Get("name").(string)); err != nil {
        return nil, fmt.Errorf("error deleting role: %w", err)
    }
    return nil, nil
}

func getRole(ctx context.Context, s logical.Storage, name string) (*roleEntry, error) {
    if name == "" {
        return nil, fmt.Errorf("missing role name")
    }
    entry, err := s.Get(ctx, rolePrefix+name)
    if err != nil {
        return nil, err
    }
    if entry == nil {
        return nil, nil
    }
    var role roleEntry
    if err := entry.DecodeJSON(&role); err != nil {
        return nil, err
    }
    return &role, nil
}

func setRole(ctx context.Context, s logical.Storage, name string, role *roleEntry) error {
    entry, err := logical.StorageEntryJSON(rolePrefix+name, role)
    if err != nil {
        return err
    }
    return s.Put(ctx, entry)
}
```

Validation rules (`logical.ErrorResponse` + nil error for user mistakes)
belong in the write handler, before anything persists.

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

## Config Path (root credentials + Rotation Manager)

```go
const configPath = "config"

type exampleConfig struct {
    // Embeds rotation_schedule / rotation_window / rotation_period fields.
    automatedrotationutil.AutomatedRotationParams

    Token string `json:"token"` // root credential — never returned on read
    URL   string `json:"url"`
}

func pathConfig(b *exampleBackend) *framework.Path {
    p := &framework.Path{
        Pattern: configPath,
        DisplayAttrs: &framework.DisplayAttributes{
            OperationPrefix: operationPrefixExample,
        },
        Fields: map[string]*framework.FieldSchema{
            "token": {
                Type:        framework.TypeString,
                Description: "Root token used to manage credentials in the external system",
                Required:    true,
                DisplayAttrs: &framework.DisplayAttributes{Sensitive: true},
            },
            "url": {
                Type:        framework.TypeString,
                Description: "Base URL of the external system's API",
                Required:    true,
            },
        },
        Operations: map[logical.Operation]framework.OperationHandler{
            logical.ReadOperation:   &framework.PathOperation{Callback: b.pathConfigRead},
            logical.CreateOperation: &framework.PathOperation{Callback: b.pathConfigWrite},
            logical.UpdateOperation: &framework.PathOperation{Callback: b.pathConfigWrite},
            logical.DeleteOperation: &framework.PathOperation{Callback: b.pathConfigDelete},
        },
        ExistenceCheck:  b.pathConfigExistenceCheck,
        HelpSynopsis:    pathConfigHelpSynopsis,
        HelpDescription: pathConfigHelpDescription,
    }

    // Adds the automated-rotation field schema (rotation_schedule, etc.)
    automatedrotationutil.AddAutomatedRotationFields(p.Fields)
    return p
}

func (b *exampleBackend) pathConfigRead(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
    config, err := getConfig(ctx, req.Storage)
    if err != nil {
        return nil, err
    }
    if config == nil {
        return nil, nil
    }
    configData := map[string]interface{}{
        "url": config.URL, // note: token is deliberately omitted
    }
    config.PopulateAutomatedRotationData(configData)
    return &logical.Response{Data: configData}, nil
}

func (b *exampleBackend) pathConfigWrite(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    config, err := getConfig(ctx, req.Storage)
    if err != nil {
        return nil, err
    }
    if config == nil {
        if req.Operation == logical.UpdateOperation {
            return nil, errors.New("config not found during update operation")
        }
        config = new(exampleConfig)
    }

    if token, ok := d.GetOk("token"); ok {
        config.Token = token.(string)
    } else if req.Operation == logical.CreateOperation {
        return logical.ErrorResponse("missing token"), nil
    }
    if url, ok := d.GetOk("url"); ok {
        config.URL = url.(string)
    }

    // Rotation Manager (Vault Enterprise). Disabled by default: unless the
    // operator sets a rotation schedule/period, nothing registers and the
    // engine behaves identically on OSS Vault.
    if err := config.ParseAutomatedRotationFields(d); err != nil {
        return logical.ErrorResponse(err.Error()), nil
    }
    if config.ShouldDeregisterRotationJob() {
        deregisterReq := &rotation.RotationJobDeregisterRequest{
            MountPoint: req.MountPoint,
            ReqPath:    req.Path,
        }
        if err := b.System().DeregisterRotationJob(ctx, deregisterReq); err != nil {
            return logical.ErrorResponse("error deregistering rotation job: %s", err), nil
        }
    } else if config.ShouldRegisterRotationJob() {
        cfgReq := &rotation.RotationJobConfigureRequest{
            MountPoint:       req.MountPoint,
            ReqPath:          req.Path,
            RotationSchedule: config.RotationSchedule,
            RotationWindow:   config.RotationWindow,
            RotationPeriod:   config.RotationPeriod,
        }
        if _, err := b.System().RegisterRotationJob(ctx, cfgReq); err != nil {
            return logical.ErrorResponse("error registering rotation job: %s", err), nil
        }
    }

    entry, err := logical.StorageEntryJSON(configPath, config)
    if err != nil {
        return nil, err
    }
    if err := req.Storage.Put(ctx, entry); err != nil {
        return nil, err
    }

    b.reset() // next getClient picks up the new config
    return nil, nil
}

func (b *exampleBackend) pathConfigDelete(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
    err := req.Storage.Delete(ctx, configPath)
    if err == nil {
        b.reset()
    }
    return nil, err
}

func getConfig(ctx context.Context, s logical.Storage) (*exampleConfig, error) {
    entry, err := s.Get(ctx, configPath)
    if err != nil {
        return nil, err
    }
    if entry == nil {
        return nil, nil
    }
    config := new(exampleConfig)
    if err := entry.DecodeJSON(&config); err != nil {
        return nil, fmt.Errorf("error reading configuration: %w", err)
    }
    return config, nil
}
```

Registration failures on OSS Vault (unsupported) surface as actionable
errors only when the user explicitly enabled automated rotation — never at
plugin load.

## Dynamic Credentials (framework.Secret)

```go
const exampleTokenType = "example_token"

func pathCredentials(b *exampleBackend) *framework.Path {
    return &framework.Path{
        Pattern: "creds/" + framework.GenericNameRegex("name"),
        DisplayAttrs: &framework.DisplayAttributes{
            OperationPrefix: operationPrefixExample,
            OperationVerb:   "generate",
        },
        Fields: map[string]*framework.FieldSchema{
            "name": {
                Type:        framework.TypeLowerCaseString,
                Description: "Name of the role",
                Required:    true,
            },
        },
        Operations: map[logical.Operation]framework.OperationHandler{
            logical.ReadOperation: &framework.PathOperation{
                Callback: b.pathCredentialsRead,
                DisplayAttrs: &framework.DisplayAttributes{
                    OperationSuffix: "credentials",
                },
            },
        },
        HelpSynopsis:    pathCredsHelpSynopsis,
        HelpDescription: pathCredsHelpDescription,
    }
}

func (b *exampleBackend) exampleToken() *framework.Secret {
    return &framework.Secret{
        Type: exampleTokenType,
        Fields: map[string]*framework.FieldSchema{
            "token": {
                Type:        framework.TypeString,
                Description: "Generated token",
            },
        },
        Renew:  b.tokenRenew,
        Revoke: b.tokenRevoke,
    }
}

func (b *exampleBackend) pathCredentialsRead(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    roleName := d.Get("name").(string)
    role, err := getRole(ctx, req.Storage, roleName)
    if err != nil {
        return nil, err
    }
    if role == nil {
        return logical.ErrorResponse("role %q not found", roleName), nil
    }

    client, err := b.getClient(ctx, req.Storage)
    if err != nil {
        return nil, err
    }
    token, err := client.CreateToken(ctx, CreateTokenRequest{Role: role.Name})
    if err != nil {
        return nil, fmt.Errorf("error creating token: %w", err)
    }

    // Response data = exactly the fields design §3 declares.
    // InternalData = everything Revoke needs (external IDs) — Revoke must
    // not depend on the role still existing.
    resp := b.Secret(exampleTokenType).Response(map[string]interface{}{
        "token":    token.Value,
        "token_id": token.ID,
    }, map[string]interface{}{
        "token_id": token.ID,
        "role":     role.Name,
    })

    if role.TTL > 0 {
        resp.Secret.TTL = role.TTL
    }
    if role.MaxTTL > 0 {
        resp.Secret.MaxTTL = role.MaxTTL
    }
    return resp, nil
}

func (b *exampleBackend) tokenRenew(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
    roleRaw, ok := req.Secret.InternalData["role"]
    if !ok {
        return nil, fmt.Errorf("secret is missing role internal data")
    }
    role, err := getRole(ctx, req.Storage, roleRaw.(string))
    if err != nil {
        return nil, fmt.Errorf("error retrieving role: %w", err)
    }
    if role == nil {
        return nil, errors.New("error retrieving role: role is nil")
    }

    resp := &logical.Response{Secret: req.Secret}
    if role.TTL > 0 {
        resp.Secret.TTL = role.TTL
    }
    if role.MaxTTL > 0 {
        resp.Secret.MaxTTL = role.MaxTTL
    }
    return resp, nil
}

func (b *exampleBackend) tokenRevoke(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
    tokenIDRaw, ok := req.Secret.InternalData["token_id"]
    if !ok {
        return nil, fmt.Errorf("secret is missing token_id internal data")
    }
    tokenID, ok := tokenIDRaw.(string)
    if !ok || tokenID == "" {
        return nil, fmt.Errorf("invalid token_id internal data")
    }

    client, err := b.getClient(ctx, req.Storage)
    if err != nil {
        return nil, fmt.Errorf("error getting client: %w", err)
    }
    // The client treats already-deleted as success (idempotent revoke).
    if err := client.DeleteToken(ctx, tokenID); err != nil {
        return nil, fmt.Errorf("error revoking token: %w", err)
    }
    return nil, nil
}
```

## Rotation & WAL

Ordering for any external mutation (rotate, create-then-store): WAL intent →
external call → persist storage → delete WAL. Concrete rotate-role shape:

```go
const rotateWALKey = "exampleRotateCredential"

type rotateCredentialWAL struct {
    Version   int       `json:"version"`
    RoleName  string    `json:"role_name"`
    NewSecret string    `json:"new_secret"`
    CreatedAt time.Time `json:"created_at"`
}

func (b *exampleBackend) rotateCredential(ctx context.Context, req *logical.Request, role *roleEntry) error {
    newSecret, err := generateSecret()
    if err != nil {
        return err
    }

    // 1. WAL intent BEFORE the external call — with everything a recovery
    //    pass needs to finish or undo the job.
    walID, err := framework.PutWAL(ctx, req.Storage, rotateWALKey, &rotateCredentialWAL{
        Version:   1,
        RoleName:  role.Name,
        NewSecret: newSecret,
        CreatedAt: time.Now(),
    })
    if err != nil {
        return fmt.Errorf("error writing WAL entry: %w", err)
    }

    // 2. External mutation.
    client, err := b.getClient(ctx, req.Storage)
    if err != nil {
        return err
    }
    if err := client.UpdateSecret(ctx, role.Name, newSecret); err != nil {
        // External call failed — the WAL stays; the rollback/tidy pass
        // verifies external state and cleans up.
        return fmt.Errorf("error rotating credential: %w", err)
    }

    // 3. Persist storage only after the external system accepted the change.
    role.LastRotation = time.Now()
    if err := setRole(ctx, req.Storage, role.Name, role); err != nil {
        return err
    }

    // 4. Success — drop the WAL.
    if err := framework.DeleteWAL(ctx, req.Storage, walID); err != nil {
        b.Logger().Warn("error deleting WAL", "WAL ID", walID, "error", err)
    }
    return nil
}
```

Recovery via `WALRollback` (wired in the `framework.Backend` literal above,
with `WALRollbackMinAge` so in-flight requests are not rolled back):

```go
func (b *exampleBackend) walRollback(ctx context.Context, req *logical.Request, kind string, data interface{}) error {
    if kind != rotateWALKey {
        return fmt.Errorf("unknown WAL kind %q", kind)
    }
    var wal rotateCredentialWAL
    if err := mapstructure.Decode(data, &wal); err != nil {
        return err
    }
    // Reconcile: check external state; complete the rotation (persist) or
    // retry the external call. Never persist a credential the external
    // system did not accept; never lose track of one it did.
    return b.reconcileRotation(ctx, req.Storage, &wal)
}
```

## Known SDK Gotchas

Framework-level landmines that apply to every engine:

1. A `framework.Path` that registers `logical.CreateOperation` but has no
   `ExistenceCheck` panics at backend initialization — singleton paths like
   `config` included (this is why the config example above wires
   `pathConfigExistenceCheck`).
2. `automatedrotationutil.ParseAutomatedRotationFields` requires
   `rotation_schedule` and `rotation_window` to be set together; a schedule
   without a window is a validation error — write config and tests
   accordingly.
3. `automatedrotationutil.AddAutomatedRotationFields` registers
   `rotation_period` as `framework.TypeInt`. If the engine needs its own
   duration-typed rotation period (e.g. per-role), use a different field name
   AND a different storage key to avoid the collision.

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
