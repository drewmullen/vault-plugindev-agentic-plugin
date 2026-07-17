---
name: vault-plugin-config-client
description: Vault secrets engine config/client seam — config path CRUD with root-credential hygiene, Rotation Manager registration (disabled by default), cached client with read-lock upgrade, cross-node invalidation, and root-credential rotation via config/rotate-root. Use when implementing client.go, path_config.go, or root rotation.
user-invocable: false
---

# Config & Client Seam

One activity, three files: `path_config.go` (root credential storage),
`client.go` (`newClient(config)` construction), and the `getClient` /
`reset` / `invalidate` methods on the backend (`backend.go`). The config
write's cache reset, the double-checked `getClient`, and client construction
only make sense together — implement them as a unit. Root-credential
rotation (`config/rotate-root`) rotates the credential this seam stores, so
it lives here too.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-*` repos, local
checkouts). Web research is for the *target system's* API only. The examples
use a generic `example` engine; substitute the engine's own names, fields,
and client operations from design §2/§3.

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
same seam (struct field injection in `getTestBackend`). `newClient(config)`
in `client.go` is the only place the real transport is constructed.

**Warning — `reset()` is not a rotation tool.** `reset()`/`invalidate` exist
ONLY for cross-node config changes (replication invalidation). A rotation or
config handler that changes the credential the client itself authenticates
with must swap it IN-PLACE on the live client via a narrow client method
(e.g. `Client.UpdateToken(newToken)`) — never call reset-and-rebuild from
inside a handler: it silently replaces the injected fake client in tests and
races with in-flight requests in production.

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

The `b.reset()` on write is the config→client half of the seam: it applies
only when a NON-credential field (URL, CA cert) changed. If the write also
changed the credential, prefer the in-place swap discussed above.

## Root-Credential Rotation (`config/rotate-root`)

Rotates the credential stored in config using the create-before-delete
pattern: mint a replacement, persist it as canonical, swap the live client
in-place, then best-effort clean up the old credential. This method is also
the `RotateCredential` callback registered in the `framework.Backend`
literal, so the Rotation Manager and the manual endpoint share one code
path.

```go
func pathConfigRotateRoot(b *exampleBackend) *framework.Path {
    return &framework.Path{
        Pattern: "config/rotate-root",
        DisplayAttrs: &framework.DisplayAttributes{
            OperationPrefix: operationPrefixExample,
            OperationVerb:   "rotate",
            OperationSuffix: "config",
        },
        Operations: map[logical.Operation]framework.OperationHandler{
            logical.UpdateOperation: &framework.PathOperation{
                Callback: func(ctx context.Context, req *logical.Request, _ *framework.FieldData) (*logical.Response, error) {
                    return nil, b.rotateRootCredential(ctx, req)
                },
                // Root rotation mutates shared state — always run on the
                // active node of the primary cluster.
                ForwardPerformanceStandby:   true,
                ForwardPerformanceSecondary: true,
            },
        },
        HelpSynopsis:    pathRotateRootHelpSynopsis,
        HelpDescription: pathRotateRootHelpDescription,
    }
}

const rotateRootWALKey = "exampleRotateRoot"

func (b *exampleBackend) rotateRootCredential(ctx context.Context, req *logical.Request) error {
    config, err := getConfig(ctx, req.Storage)
    if err != nil {
        return err
    }
    if config == nil {
        return errors.New("backend is not configured: write config first")
    }
    client, err := b.getClient(ctx, req.Storage)
    if err != nil {
        return err
    }

    // 1. Mint the replacement BEFORE touching the old credential, then
    //    2. WAL the new credential's ID so a crash before persist lets the
    //    rollback pass revoke it (the old credential is still canonical).
    newToken, err := client.CreateRootToken(ctx)
    if err != nil {
        return fmt.Errorf("error minting replacement root credential: %w", err)
    }
    walID, err := framework.PutWAL(ctx, req.Storage, rotateRootWALKey, map[string]interface{}{
        "token_id": newToken.ID,
    })
    if err != nil {
        _ = client.DeleteToken(ctx, newToken.ID) // best effort — do not orphan
        return fmt.Errorf("error writing WAL entry: %w", err)
    }

    // 3. Persist: the new credential is now canonical.
    oldTokenID := config.TokenID
    config.Token, config.TokenID = newToken.Value, newToken.ID
    entry, err := logical.StorageEntryJSON(configPath, config)
    if err != nil {
        return err
    }
    if err := req.Storage.Put(ctx, entry); err != nil {
        return fmt.Errorf("error saving config after rotation: %w", err)
    }

    // 4. Swap the live client's credential IN-PLACE (never reset-and-rebuild).
    client.UpdateToken(newToken.Value)

    // 5. Success — drop the WAL, then best-effort delete the old credential.
    //    The new credential is already persisted and canonical, so failures
    //    from here on must not fail the rotation.
    if err := framework.DeleteWAL(ctx, req.Storage, walID); err != nil {
        b.Logger().Warn("error deleting rotate-root WAL", "WAL ID", walID, "error", err)
    }
    if oldTokenID != "" {
        if err := client.DeleteToken(ctx, oldTokenID); err != nil {
            b.Logger().Warn("failed to delete old root credential after rotation",
                "old_token_id", oldTokenID, "error", err)
        }
    }
    return nil
}
```

- If the target system cannot mint a second credential for the same
  principal (single-credential systems, e.g. a password), the shape inverts:
  generate the new secret locally, WAL it, update it remotely, then persist
  — see the static-role rotation pattern in `vault-plugin-static-roles` for
  that ordering.
- The WAL kind must be handled in the backend's `walRollback` dispatcher:
  revoke the WAL'd token ID if the entry survives (idempotent — already
  deleted is success).

## Known SDK Gotchas (rotation config)

1. `automatedrotationutil.ParseAutomatedRotationFields` requires
   `rotation_schedule` and `rotation_window` to be set together; a schedule
   without a window is a validation error — write config and tests
   accordingly.
2. `automatedrotationutil.AddAutomatedRotationFields` registers
   `rotation_period` as `framework.TypeInt`. If the engine needs its own
   duration-typed rotation period (e.g. per-role), use a different field name
   AND a different storage key to avoid the collision.
