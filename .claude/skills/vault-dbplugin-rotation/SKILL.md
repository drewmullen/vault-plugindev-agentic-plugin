---
name: vault-dbplugin-rotation
description: Vault database plugin UpdateUser patterns — password change with rotation statements or default, expiration change (renewal) with explicit unsupported error, public-key change gate, root self-rotation that updates the in-memory config and raw config map and rebuilds the client, SelfManagedPassword handling, and idempotency under Vault's retry. Use when implementing rotation.go.
user-invocable: false
---

# Rotation (`UpdateUser`)

Every rotation-shaped operation in Vault core funnels into one plugin
method. The request tells you which change is requested; at least one of
`Password`, `Expiration`, `PublicKey` is non-nil.

| Vault operation | `req.Username` | Non-nil change | `Statements` carried |
|---|---|---|---|
| `rotate-root/<name>` (manual or scheduled) | root (config) username | `Password` | `root_rotation_statements` |
| `rotate-role/<static>` (manual or scheduled) | static-role username | `Password` (or `PublicKey`) | `rotation_statements` |
| static-role import (first write) | static-role username | `Password` | `rotation_statements` |
| lease renew with `renew_statements` | dynamic username | `Expiration` | `renew_statements` |

The plugin cannot tell manual from scheduled and must not try. Vault wraps
static rotations in its own WAL and **retries with the same new password**
after a transient failure — `UpdateUser` must therefore be idempotent.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases. Web research is for the *target
system's* admin API only.

## UpdateUser

```go
func (d *ExampleDB) UpdateUser(ctx context.Context, req dbplugin.UpdateUserRequest) (dbplugin.UpdateUserResponse, error) {
    if req.Password == nil && req.Expiration == nil && req.PublicKey == nil {
        return dbplugin.UpdateUserResponse{}, errors.New("no change requested")
    }
    if req.Username == "" {
        return dbplugin.UpdateUserResponse{}, errors.New("username is required")
    }

    if req.Password != nil {
        if err := d.changePassword(ctx, req.Username, req.Password, req.SelfManagedPassword); err != nil {
            return dbplugin.UpdateUserResponse{}, err
        }
    }
    if req.Expiration != nil {
        if err := d.changeExpiration(ctx, req.Username, req.Expiration); err != nil {
            return dbplugin.UpdateUserResponse{}, err
        }
    }
    if req.PublicKey != nil {
        // Only when design §3 marks rsa_private_key supported; otherwise:
        return dbplugin.UpdateUserResponse{}, errors.New("public key credentials are not supported")
    }
    return dbplugin.UpdateUserResponse{}, nil
}
```

## Password Change

```go
func (d *ExampleDB) changePassword(ctx context.Context, username string, change *dbplugin.ChangePassword, selfManaged string) error {
    if change.NewPassword == "" {
        return errors.New("new password is required")
    }
    client, release, err := d.borrow()
    if err != nil {
        return err
    }

    // Design §4 decides: honor SelfManagedPassword (authenticate AS the
    // user) or ignore it (documented). Honoring means a one-off client:
    //   if selfManaged != "" { client, err = d.newClient(cfgAs(username, selfManaged)); defer client.Close() }

    if len(change.Statements.Commands) > 0 {
        data := map[string]string{"name": username, "username": username, "password": change.NewPassword}
        err = client.ExecuteStatements(ctx, change.Statements.Commands, data)
    } else {
        err = client.SetPassword(ctx, username, change.NewPassword)
    }
    release()
    if err != nil {
        return fmt.Errorf("failed to change password for %q: %w", username, err)
    }

    // Root self-rotation: keep the live plugin authenticating.
    d.mu.RLock()
    isRoot := username == d.config.Username
    d.mu.RUnlock()
    if isRoot {
        return d.adoptRootPassword(change.NewPassword)
    }
    return nil
}
```

Ordering: **target first, memory second.** If the target rejects the new
password nothing in the plugin changes; if it accepts, the in-memory
credential must follow immediately or the very next call authenticates
with a dead password.

## Root Self-Rotation

```go
// adoptRootPassword swaps the root credential in place after the target
// accepted it: config struct, raw config map (Vault re-sends it on the
// next Initialize), and a rebuilt client. Never reset()/rebuild from
// scratch elsewhere — this is the one place the client identity changes.
func (d *ExampleDB) adoptRootPassword(newPassword string) error {
    d.mu.Lock()
    defer d.mu.Unlock()

    d.config.Password = newPassword
    if d.rawConfig == nil {
        d.rawConfig = map[string]interface{}{}
    }
    d.rawConfig["password"] = newPassword

    client, err := d.newClient(d.config)
    if err != nil {
        // Target already has the new password; Vault will persist it and
        // re-Initialize on next use. Surface the error, do not wedge state.
        return fmt.Errorf("password rotated but failed to rebuild client: %w", err)
    }
    if d.client != nil {
        _ = d.client.Close()
    }
    d.client = client
    return nil
}
```

What Vault does after this returns nil: writes the new password into
`connection_details`, calls `Close`, and `Initialize`s with the updated map
on the next request. The plugin must survive both `Close` and a fresh
`Initialize` — which it does if `Initialize` is repeatable (see
`vault-dbplugin-connection`).

`secretValues()` reads `d.config.Password`, so the sanitizer redacts the
NEW password from any later error automatically.

## Expiration Change (renewal)

```go
func (d *ExampleDB) changeExpiration(ctx context.Context, username string, change *dbplugin.ChangeExpiration) error {
    if !targetSupportsExpiry {
        // Loud, not silent: an operator who set renew_statements on a target
        // without account expiry must find out at renew time, not never.
        return errors.New("expiration changes are not supported by this plugin")
    }
    client, release, err := d.borrow()
    if err != nil {
        return err
    }
    defer release()
    if len(change.Statements.Commands) > 0 {
        data := map[string]string{"name": username, "username": username, "expiration": change.NewExpiration.Format(time.RFC3339)}
        return client.ExecuteStatements(ctx, change.Statements.Commands, data)
    }
    return client.SetExpiration(ctx, username, change.NewExpiration)
}
```

Vault only calls `UpdateUser(Expiration)` when the role has
`renew_statements`; with none set, renewals extend the lease without a
plugin call. The design §4 Expiration subsection records which of those two
worlds the plugin lives in.

## Idempotency Under Retry

- Setting the same password twice must succeed (targets that reject
  "password unchanged" need the client to treat that as success).
- `adoptRootPassword` with the already-current password is a no-op rebuild —
  harmless.
- Never store "last rotated" state in the plugin; Vault owns rotation
  bookkeeping.

## Gotchas

1. **Do not call `Initialize` from inside `UpdateUser`** to pick up the new
   password — it re-decodes the OLD raw map. Mutate `rawConfig` and rebuild
   the client as shown.
2. **Statements may carry `{{password}}`** — never wrap the rendered
   statement text into the returned error.
3. **`SelfManagedPassword` ignored ≠ unsupported.** Ignoring is allowed
   when design §4 says so; silently using it as the *new* password is a
   defect (it is the CURRENT password of a self-managed account).
