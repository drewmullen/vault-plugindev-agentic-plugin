---
name: vault-dbplugin-users
description: Vault database plugin user lifecycle — NewUser with username-template rendering and target-limit enforcement, credential-type gate, creation-statement parsing (SQL templated via dbutil.QueryHelper or JSON schema), expiration application, atomic create-or-rollback; DeleteUser with revocation statements or default delete and idempotent not-found handling. Use when implementing users.go.
user-invocable: false
---

# Users (`NewUser`, `DeleteUser`)

Vault's `creds/<role>` read arrives as a fully formed `NewUserRequest`: the
password is already generated under the mount's password policy, the
expiration already equals lease expiry + 5s, `DisplayName` is already
sanitized to `[A-Za-z0-9_-]`, and `Statements` are the role's
`creation_statements`. The plugin renders a username, applies the
statements, and returns the username. Lease revocation arrives as
`DeleteUserRequest` with the role's `revocation_statements`.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases. Web research is for the *target
system's* admin API only.

## NewUser

```go
func (d *ExampleDB) NewUser(ctx context.Context, req dbplugin.NewUserRequest) (dbplugin.NewUserResponse, error) {
    client, release, err := d.borrow()
    if err != nil {
        return dbplugin.NewUserResponse{}, err
    }
    defer release()

    // 1. Gate on credential type BEFORE any target call.
    if req.CredentialType != dbplugin.CredentialTypePassword {
        return dbplugin.NewUserResponse{}, fmt.Errorf("unsupported credential type %q", req.CredentialType.String())
    }

    // 2. Parse statements BEFORE any target call (errors name keys, not values).
    spec, err := parseCreationStatements(req.Statements.Commands)
    if err != nil {
        return dbplugin.NewUserResponse{}, err
    }

    // 3. Render + constrain the username.
    username, err := d.generateUsername(req.UsernameConfig)
    if err != nil {
        return dbplugin.NewUserResponse{}, fmt.Errorf("failed to generate username: %w", err)
    }

    // 4. Mutate the target; roll back on partial failure.
    createReq := CreateUserRequest{Username: username, Password: req.Password, Roles: spec.Roles}
    if !req.Expiration.IsZero() && targetSupportsExpiry {
        createReq.Expiration = req.Expiration
    }
    if err := client.CreateUser(ctx, createReq); err != nil {
        // A conflict means the account is NOT ours (template collision or a
        // pre-existing user): report it, never delete it. Every other
        // failure may have left a half-created user — roll it back.
        if !errors.Is(err, ErrUserExists) {
            d.rollbackUser(ctx, client, username, req.RollbackStatements)
        }
        return dbplugin.NewUserResponse{}, fmt.Errorf("failed to create user %q: %w", username, err)
    }
    return dbplugin.NewUserResponse{Username: username}, nil
}

func (d *ExampleDB) generateUsername(meta dbplugin.UsernameMetadata) (string, error) {
    // Called while borrow() holds the read lock — read the field directly.
    name, err := d.usernameProducer.Generate(meta)
    if err != nil {
        return "", err
    }
    // Enforce target limits from design §3 Username Generation.
    if len(name) > maxUsernameLength {
        name = name[:maxUsernameLength]
    }
    return strings.ToLower(name), nil
}

func (d *ExampleDB) rollbackUser(ctx context.Context, client Client, username string, rollback dbplugin.Statements) {
    // Best effort: rollback statements if the role defines them, else delete.
    if len(rollback.Commands) > 0 {
        _ = client.ExecuteStatements(ctx, rollback.Commands, map[string]string{"name": username, "username": username})
        return
    }
    if err := client.DeleteUser(ctx, username); err != nil && !errors.Is(err, ErrUserNotFound) {
        // Log identifier only; the original create error is what the caller returns.
        d.logger().Warn("rollback of partially created user failed", "username", username)
    }
}
```

Note on locking: `borrow()` holds the read lock for the whole method, so
helpers called from it read struct fields directly and never re-lock.

Ordering matters: **type gate → parse → render → mutate**. Nothing touches
the target until every local check passes, so a bad role never leaves a
half-created user.

Rollback is for *our* partial user only. The concrete client translates the
target's conflict response (HTTP 409, SQL "already exists") into
`ErrUserExists` so `NewUser` can tell "never created" from "created but the
grant failed"; deleting on a conflict would destroy someone else's account.

## Statement Parsing

### JSON schema (non-SQL targets)

```go
type creationSpec struct {
    Roles []string `json:"roles"`
}

func parseCreationStatements(cmds []string) (creationSpec, error) {
    var spec creationSpec
    for _, cmd := range cmds {
        cmd = strings.TrimSpace(cmd)
        if cmd == "" {
            continue
        }
        var s creationSpec
        if err := json.Unmarshal([]byte(cmd), &s); err != nil {
            return creationSpec{}, fmt.Errorf("creation_statements must be JSON with a \"roles\" array: %w", err)
        }
        spec.Roles = append(spec.Roles, s.Roles...)
    }
    if len(spec.Roles) == 0 {
        return creationSpec{}, dbutil.ErrEmptyCreationStatement // or apply the design's default role
    }
    return spec, nil
}
```

### SQL templates (SQL targets)

```go
// In the SQL client, one transaction for the whole statement set.
func (c *sqlClient) ExecuteStatements(ctx context.Context, stmts []string, data map[string]string) error {
    db, err := c.producer.Connection(ctx)
    if err != nil {
        return err
    }
    tx, err := db.(*sql.DB).BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer func() { _ = tx.Rollback() }()
    for _, stmt := range stmts {
        for _, q := range strutil.ParseArbitraryStringSlice(stmt, ";") {
            q = strings.TrimSpace(q)
            if q == "" {
                continue
            }
            if _, err := tx.ExecContext(ctx, dbutil.QueryHelper(q, data)); err != nil {
                return fmt.Errorf("statement failed: %w", err) // never include q — it carries {{password}}
            }
        }
    }
    return tx.Commit()
}
```

`data` for creation: `{"name": u, "username": u, "password": p,
"expiration": expirationStr}`. Never log or wrap the rendered query.

## DeleteUser

```go
func (d *ExampleDB) DeleteUser(ctx context.Context, req dbplugin.DeleteUserRequest) (dbplugin.DeleteUserResponse, error) {
    client, release, err := d.borrow()
    if err != nil {
        return dbplugin.DeleteUserResponse{}, err
    }
    defer release()

    if len(req.Statements.Commands) > 0 {
        data := map[string]string{"name": req.Username, "username": req.Username}
        if err := client.ExecuteStatements(ctx, req.Statements.Commands, data); err != nil {
            return dbplugin.DeleteUserResponse{}, fmt.Errorf("revocation statements failed for %q: %w", req.Username, err)
        }
        return dbplugin.DeleteUserResponse{}, nil
    }

    err = client.DeleteUser(ctx, req.Username)
    if errors.Is(err, ErrUserNotFound) {
        return dbplugin.DeleteUserResponse{}, nil // idempotent: already gone is success
    }
    if err != nil {
        return dbplugin.DeleteUserResponse{}, fmt.Errorf("failed to delete user %q: %w", req.Username, err)
    }
    return dbplugin.DeleteUserResponse{}, nil
}
```

Rules:

- Not-found is success. Vault retries revocation on failure; a plugin that
  errors on a missing user makes the lease unrevokable.
- Never consult per-user state kept in memory — Vault may call `DeleteUser`
  on a brand-new process after a plugin reload.
- Concrete clients translate the target's not-found (HTTP 404, SQL "role
  does not exist") into `ErrUserNotFound` and its conflict (HTTP 409, SQL
  "already exists") into `ErrUserExists` — string matching lives in ONE
  place, the client.

## Expiration

- Apply `req.Expiration` in `NewUser` only when design §4 says the target
  supports account expiry. Format per target (`VALID UNTIL '<RFC3339>'`,
  `expires_at` epoch, …) inside the client.
- When unsupported, ignore it silently in `NewUser` (the lease still expires
  the credential) — but see `vault-dbplugin-rotation` for the `UpdateUser`
  renewal case, which must **not** be silent.
