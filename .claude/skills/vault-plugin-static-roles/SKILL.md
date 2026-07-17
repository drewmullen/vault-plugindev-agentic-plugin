---
name: vault-plugin-static-roles
description: Vault secrets engine static-role patterns — static account entries managing pre-existing external accounts, rotation priority queue with background ticker, first-touch import rotation, WAL-safe password rotation with reuse-on-retry, manual rotate-role endpoint, and lease-less static-creds read. Use when implementing path_static_roles.go, path_static_creds.go, or the rotation queue.
user-invocable: false
---

# Static Roles (rotation queue + static creds)

A static role manages a *pre-existing* external account: Vault takes over
its password and rotates it on a period. The activity spans three files that
are not comprehensible alone: `path_static_roles.go` (CRUD whose write
pushes onto the rotation queue), `rotation.go` (priority queue, background
ticker, WAL-safe rotation), and `path_static_creds.go` (a plain read of the
current password — no lease). Contrast with dynamic credentials
(`vault-plugin-dynamic-creds`): nothing is minted per-request and rotation
happens out-of-band, not on read.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-*` repos, local
checkouts). Web research is for the *target system's* API only. The examples
use a generic `example` engine; substitute the engine's own names, fields,
and client operations from design §2/§3.

## Backend Additions and Lifecycle Wiring

Static roles add state to the backend struct and two lifecycle hooks to the
`framework.Backend` literal:

```go
type exampleBackend struct {
    *framework.Backend
    lock   sync.RWMutex
    client Client

    // credRotationQueue tracks static roles needing periodic rotation.
    // cancelQueue stops the background ticker on Clean.
    credRotationQueue *queue.PriorityQueue
    cancelQueue       context.CancelFunc

    // roleLocks stripe-locks per role name so a manual rotate, a CRUD
    // write, and the ticker never mutate the same role concurrently.
    roleLocks []*locksutil.LockEntry
}

// In backend(): credRotationQueue: queue.New(), roleLocks: locksutil.CreateLocks()
// In the framework.Backend literal:
//   InitializeFunc: b.initialize,
//   Clean:          b.clean,
// SealWrapStorage must include staticRolePath + "*" (current passwords live there).

func (b *exampleBackend) initialize(ctx context.Context, req *logical.InitializationRequest) error {
    // Do not block the mount: populate the queue in the background.
    ictx, cancel := context.WithCancel(context.Background())
    b.cancelQueue = cancel
    go b.initQueue(ictx, req)
    return nil
}

func (b *exampleBackend) initQueue(ctx context.Context, req *logical.InitializationRequest) {
    // Only the active node of the primary (or a local mount) rotates.
    replState := b.System().ReplicationState()
    if (b.System().LocalMount() || !replState.HasState(consts.ReplicationPerformanceSecondary)) &&
        !replState.HasState(consts.ReplicationDRSecondary) &&
        !replState.HasState(consts.ReplicationPerformanceStandby) {
        b.populateQueue(ctx, req.Storage)
        go b.runTicker(ctx, req.Storage)
    }
}

func (b *exampleBackend) clean(_ context.Context) {
    b.lock.Lock()
    defer b.lock.Unlock()
    if b.cancelQueue != nil {
        b.cancelQueue()
    }
    b.credRotationQueue = nil
}
```

Because the ticker and request handlers touch the queue concurrently, wrap
every queue operation (`Push`, `Pop`, `PopByKey`) in a helper that takes the
backend read lock and nil-checks `credRotationQueue` first.

## Static Role Entry

```go
const staticRolePath = "static-role/"

type staticRoleEntry struct {
    Version       int           `json:"version"`
    Name          string        `json:"name"`
    Username      string        `json:"username"` // pre-existing external account
    Password      string        `json:"password"`      // current — returned by static-cred read
    LastPassword  string        `json:"last_password"` // previous — grace for in-flight consumers
    LastRotation  time.Time     `json:"last_vault_rotation"` // zero ⇒ Vault has never rotated it
    NextRotation  time.Time     `json:"next_vault_rotation"`
    RotationPeriod time.Duration `json:"rotation_period"`
}

func (r *staticRoleEntry) SetNextRotation(from time.Time) {
    r.NextRotation = from.Add(r.RotationPeriod)
}

// PasswordTTL is approximate (the ticker only checks every few seconds);
// clamp negatives to zero.
func (r *staticRoleEntry) PasswordTTL() time.Duration {
    ttl := time.Until(r.NextRotation).Round(time.Second)
    if ttl < 0 {
        ttl = 0
    }
    return ttl
}
```

## Static Role CRUD (write couples to the queue)

The write handler is where first-touch bootstrap happens: on create, Vault
rotates the account's password immediately ("import rotation") so the
external credential the operator supplied is retired — unless the design
opts into `skip_import_rotation`. Every create/update ends by (re)pushing
the role onto the rotation queue. Register create/update/delete with
`ForwardPerformanceStandby: true, ForwardPerformanceSecondary: true` — only
the node running the queue may mutate static roles.

```go
const queueTickSeconds = 5

func (b *exampleBackend) pathStaticRolesWrite(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    name := d.Get("name").(string)

    lock := locksutil.LockForKey(b.roleLocks, name)
    lock.Lock()
    defer lock.Unlock()

    role, err := getStaticRole(ctx, req.Storage, name)
    if err != nil {
        return nil, err
    }
    isCreate := req.Operation == logical.CreateOperation
    if role == nil {
        role = &staticRoleEntry{Version: 1, Name: name}
    }

    if usernameRaw, ok := d.GetOk("username"); ok {
        username := usernameRaw.(string)
        if !isCreate && username != role.Username {
            return logical.ErrorResponse("cannot update static role username"), nil
        }
        role.Username = username
    } else if isCreate {
        return logical.ErrorResponse("username is required to manage a static account"), nil
    }

    if periodRaw, ok := d.GetOk("rotation_period"); ok {
        period := periodRaw.(int)
        if period < queueTickSeconds {
            return logical.ErrorResponse("rotation_period must be %d seconds or more", queueTickSeconds), nil
        }
        role.RotationPeriod = time.Duration(period) * time.Second
    } else if isCreate {
        return logical.ErrorResponse("rotation_period is required to create static roles"), nil
    }

    var item *queue.Item
    switch {
    case isCreate:
        // First-touch import rotation: rotate now so the operator-supplied
        // password is retired. rotateStaticPassword persists the role.
        if err := b.rotateStaticPassword(ctx, req.Storage, &rotateInput{Name: name, Role: role}); err != nil {
            return nil, err
        }
        item = &queue.Item{Key: name}
    default:
        role.SetNextRotation(role.LastRotation) // period may have changed
        if err := setStaticRole(ctx, req.Storage, name, role); err != nil {
            return nil, err
        }
        // Keep the EXISTING queue item — it may carry a WAL ID from an
        // in-flight rotation. Pop by key, update, re-push.
        item, err = b.popFromRotationQueueByKey(name)
        if err != nil {
            item = &queue.Item{Key: name}
        }
    }
    item.Priority = role.NextRotation.Unix()
    if err := b.pushItem(item); err != nil {
        return nil, err
    }
    return nil, nil
}
```

Delete removes the role from storage, pops its queue item, and purges any
WAL entries recorded for its name (list WALs, match on role name, delete).
Read returns username, rotation_period, and last_vault_rotation — never the
password (that is the static-cred path's job).

## Rotation Queue

`populateQueue` (at initialize) lists static roles from storage and pushes
one item per role with `Priority = NextRotation.Unix()`. While doing so it
reconciles surviving WALs: a WAL older than the role's `LastRotation` is
stale (delete it); a newer one means a rotation died mid-flight — store the
WAL ID in `item.Value` and set the priority to now so it retries first.

```go
func (b *exampleBackend) runTicker(ctx context.Context, s logical.Storage) {
    tick := time.NewTicker(queueTickSeconds * time.Second)
    defer tick.Stop()
    for {
        select {
        case <-tick.C:
            for b.rotateExpiredCredential(ctx, s) {
            }
        case <-ctx.Done():
            return
        }
    }
}

// rotateExpiredCredential pops the highest-priority item; returns false when
// the queue is empty or the front item is not yet due (re-push it first).
func (b *exampleBackend) rotateExpiredCredential(ctx context.Context, s logical.Storage) bool {
    item, err := b.popFromRotationQueue()
    if err != nil || item == nil {
        return false
    }

    lock := locksutil.LockForKey(b.roleLocks, item.Key)
    lock.Lock()
    defer lock.Unlock()

    role, err := getStaticRole(ctx, s, item.Key)
    if err != nil {
        item.Priority = time.Now().Add(10 * time.Second).Unix() // back off, retry
        _ = b.pushItem(item)
        return true
    }
    if role == nil {
        return true // deleted since queueing — drop the item
    }
    if time.Now().Unix() < item.Priority {
        _ = b.pushItem(item) // not due yet — put it back, stop the sweep
        return false
    }

    input := &rotateInput{Name: item.Key, Role: role}
    if walID, ok := item.Value.(string); ok {
        input.WALID = walID // resume the interrupted rotation
    }
    if err := b.rotateStaticPassword(ctx, s, input); err != nil {
        b.Logger().Error("static rotation failed", "role", item.Key, "error", err)
        item.Priority = time.Now().Add(10 * time.Second).Unix() // back off
        item.Value = input.WALID                                // keep the WAL for resume
        _ = b.pushItem(item)
        return true
    }

    item.Value = ""
    item.Priority = role.NextRotation.Unix()
    _ = b.pushItem(item)
    return true
}
```

## WAL-Safe Password Rotation

Single-credential ordering (the account has exactly one password, so there
is no create-before-delete): generate locally → WAL the new password →
update remotely → persist → delete WAL. If Vault dies after the remote
update but before persist, the WAL is the only copy of the password the
external system now expects — that is why the WAL is written first and why
a resumed rotation MUST reuse the WAL's password rather than generate a
fresh one.

```go
const staticWALKey = "staticRotation"

type staticRotationWAL struct {
    Version      int       `json:"version"`
    RoleName     string    `json:"role_name"`
    Username     string    `json:"username"`
    NewPassword  string    `json:"new_password"`
    LastRotation time.Time `json:"last_vault_rotation"`
}

type rotateInput struct {
    Name  string
    Role  *staticRoleEntry
    WALID string
}

func (b *exampleBackend) rotateStaticPassword(ctx context.Context, s logical.Storage, in *rotateInput) error {
    var newPassword string

    // Resume path: reuse the password recorded by the interrupted attempt —
    // the external system may already have accepted it.
    if in.WALID != "" {
        wal, err := b.findStaticWAL(ctx, s, in.WALID)
        if err != nil {
            return err
        }
        if wal != nil {
            newPassword = wal.NewPassword
        } else {
            in.WALID = "" // WAL vanished — start fresh
        }
    }

    if in.WALID == "" {
        var err error
        newPassword, err = b.generatePassword(ctx, s)
        if err != nil {
            return err
        }
        in.WALID, err = framework.PutWAL(ctx, s, staticWALKey, &staticRotationWAL{
            Version:      1,
            RoleName:     in.Name,
            Username:     in.Role.Username,
            NewPassword:  newPassword,
            LastRotation: in.Role.LastRotation,
        })
        if err != nil {
            return fmt.Errorf("error writing WAL entry: %w", err)
        }
    }

    client, err := b.getClient(ctx, s)
    if err != nil {
        return err
    }
    if err := client.UpdatePassword(ctx, in.Role.Username, newPassword); err != nil {
        return err // WAL stays: the queue item carries the WAL ID and retries
    }

    now := time.Now()
    in.Role.LastPassword = in.Role.Password
    in.Role.Password = newPassword
    in.Role.LastRotation = now
    in.Role.SetNextRotation(now)
    if err := setStaticRole(ctx, s, in.Name, in.Role); err != nil {
        return err
    }

    if err := framework.DeleteWAL(ctx, s, in.WALID); err != nil {
        return fmt.Errorf("error deleting WAL: %w", err)
    }
    in.WALID = ""
    return nil
}
```

Generate passwords via the configured password policy
(`b.System().GeneratePasswordFromPolicy`) with a random fallback (e.g.
`base62.Random`) when no policy is set. Static-role WAL recovery happens
through the queue at initialize (`populateQueue`), NOT through the
`WALRollback` dispatcher — return nil (do not error) for the static WAL
kind there if both mechanisms coexist.

## Manual Rotation (`rotate-role/<name>`)

An update-only path that takes the role's stripe lock, pops the role's
queue item by key, calls `rotateStaticPassword`, and re-pushes with the new
`NextRotation` priority — the same code path as the ticker, so WAL handling
is identical. Register it with the same standby/secondary forwarding flags
as the CRUD writes.

## Static Creds Read (no lease)

```go
const staticCredPath = "static-cred/"

func (b *exampleBackend) pathStaticCredsRead(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
    role, err := getStaticRole(ctx, req.Storage, d.Get("name").(string))
    if err != nil {
        return nil, err
    }
    if role == nil {
        return logical.ErrorResponse("unknown static role"), nil
    }
    return &logical.Response{
        Data: map[string]interface{}{
            "username":            role.Username,
            "password":            role.Password,
            "last_password":       role.LastPassword,
            "ttl":                 role.PasswordTTL().Seconds(),
            "rotation_period":     role.RotationPeriod.Seconds(),
            "last_vault_rotation": role.LastRotation,
        },
    }, nil
}
```

No `framework.Secret`, no lease: the response is a snapshot of storage, and
the advertised `ttl` is only the time until the next scheduled rotation.
Consumers re-read after rotation; `last_password` gives in-flight consumers
a grace window.
