---
name: vault-dbplugin-testing
description: Go test patterns for Vault database plugins — direct method calls on the plugin with a fake Client injected through the newClient factory, table-driven Initialize/NewUser/UpdateUser/DeleteUser tests, sanitizer-redaction test through NewDatabaseErrorSanitizerMiddleware, root self-rotation and rollback coverage, not-initialized guard, and race-clean conventions. Use when writing or reviewing database plugin tests.
user-invocable: false
---

# Vault Database Plugin Test Patterns

Unit tests only: every test calls the plugin's methods directly with a fake
`Client` injected at the seam. There is no `logical.Request`, no
`InmemStorage`, no Vault backend — the plugin has none of those. No test in
this layer talks to a real database (opt-in live acceptance tests are a
separate layer — see `vault-dbplugin-integration-testing`). testify
(`require`/`assert`) is allowed and preferred.

**This skill is self-contained**: write tests from these patterns — do NOT
read or fetch other plugin codebases.

## The TDD Boundary in Go

Tests call `db.Initialize(...)`, `db.NewUser(...)` etc. on the scaffolded
struct whose methods are stubs returning `errNotImplemented`, so test files
compile from the first commit. The red baseline is therefore:

- `go build ./...` and `go vet ./...` PASS (scaffold compiles)
- `go test ./...` FAILS — stubbed methods return "not implemented" and the
  assertions catch it

Write real test bodies from design §3/§4 scenario tables immediately; do not
stub with `t.Skip` unless a scenario is blocked on another checklist item
(then `t.Skip("blocked on <item>")` naming it).

## Test Harness (`helpers_test.go`)

```go
func newTestDB(t *testing.T) (*ExampleDB, *fakeClient) {
    t.Helper()
    fake := newFakeClient()
    db := newExampleDB()
    db.newClient = func(cfg exampleConfig) (Client, error) {
        fake.configs = append(fake.configs, cfg) // capture what the factory saw (root password after rotation!)
        return fake, nil
    }
    return db, fake
}

func validConfig() map[string]interface{} {
    return map[string]interface{}{
        "connection_url": "https://example.test:9200",
        "username":       "vault-root",
        "password":       "root-pass-1",
    }
}

func mustInitialize(t *testing.T, db *ExampleDB, cfg map[string]interface{}, verify bool) dbplugin.InitializeResponse {
    t.Helper()
    resp, err := db.Initialize(context.Background(), dbplugin.InitializeRequest{Config: cfg, VerifyConnection: verify})
    require.NoError(t, err)
    return resp
}

func newUserReq(role string, stmts ...string) dbplugin.NewUserRequest {
    return dbplugin.NewUserRequest{
        UsernameConfig: dbplugin.UsernameMetadata{DisplayName: "token", RoleName: role},
        Statements:     dbplugin.Statements{Commands: stmts},
        CredentialType: dbplugin.CredentialTypePassword,
        Password:       "generated-by-vault-1",
        Expiration:     time.Now().Add(time.Hour),
    }
}
```

## Programmable Fake Client

```go
type fakeUser struct {
    Password   string
    Roles      []string
    Expiration time.Time
}

type fakeClient struct {
    mu      sync.Mutex
    users   map[string]*fakeUser        // observable external state
    calls   []string                    // ordered method names: "CreateUser:v-token-..."
    failOn  map[string]error            // per-method error injection
    pings   int
    closed  int
    configs []exampleConfig             // every config the factory was called with
    statements []string                 // every statement passed to ExecuteStatements
}

func newFakeClient() *fakeClient {
    return &fakeClient{users: map[string]*fakeUser{}, failOn: map[string]error{}}
}

func (f *fakeClient) Ping(ctx context.Context) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.pings++
    return f.failOn["Ping"]
}

func (f *fakeClient) CreateUser(ctx context.Context, r CreateUserRequest) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.calls = append(f.calls, "CreateUser:"+r.Username)
    if _, exists := f.users[r.Username]; exists {
        return ErrUserExists // mirrors the real client's 409 / "already exists" translation; never overwrites
    }
    if err := f.failOn["CreateUser"]; err != nil {
        // Simulate the partial-failure case the rollback test needs:
        // user exists, grant failed.
        f.users[r.Username] = &fakeUser{Password: r.Password}
        return err
    }
    f.users[r.Username] = &fakeUser{Password: r.Password, Roles: r.Roles, Expiration: r.Expiration}
    return nil
}

func (f *fakeClient) SetPassword(ctx context.Context, username, password string) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.calls = append(f.calls, "SetPassword:"+username)
    if err := f.failOn["SetPassword"]; err != nil {
        return err
    }
    u, ok := f.users[username]
    if !ok {
        return ErrUserNotFound
    }
    u.Password = password
    return nil
}

func (f *fakeClient) DeleteUser(ctx context.Context, username string) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.calls = append(f.calls, "DeleteUser:"+username)
    if err := f.failOn["DeleteUser"]; err != nil {
        return err
    }
    if _, ok := f.users[username]; !ok {
        return ErrUserNotFound // mirrors the real client's translation of 404 / "does not exist"
    }
    delete(f.users, username)
    return nil
}

func (f *fakeClient) SetExpiration(ctx context.Context, username string, expiresAt time.Time) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.calls = append(f.calls, "SetExpiration:"+username)
    if err := f.failOn["SetExpiration"]; err != nil {
        return err
    }
    u, ok := f.users[username]
    if !ok {
        return ErrUserNotFound
    }
    u.Expiration = expiresAt
    return nil
}

// ExecuteStatements records the rendered statements so tests can assert
// what reached the target. Keep it dumb: the plugin's own parsing is what
// is under test, not the fake.
func (f *fakeClient) ExecuteStatements(ctx context.Context, stmts []string, data map[string]string) error {
    f.mu.Lock(); defer f.mu.Unlock()
    f.calls = append(f.calls, "ExecuteStatements:"+data["username"])
    f.statements = append(f.statements, stmts...)
    return f.failOn["ExecuteStatements"]
}

func (f *fakeClient) Close() error { f.mu.Lock(); defer f.mu.Unlock(); f.closed++; return nil }

// Compile-time check: the fake must satisfy the full seam, or the red
// baseline errors at compile instead of failing.
var _ Client = (*fakeClient)(nil)
```

Rules:

- The fake implements EVERY method of the `Client` interface the scaffold
  declares (the `var _ Client = (*fakeClient)(nil)` line enforces it) —
  drop `SetExpiration`/`ExecuteStatements` only if the interface dropped them
- Error injection per method (`failOn`) so every failure path in design §2's
  error-semantics column gets a table case
- Call capture so tests assert WHAT reached the target, not just the response
- Real idempotency semantics: deleting an absent user returns
  `ErrUserNotFound` and creating a present one returns `ErrUserExists`,
  exactly like the production client — the idempotent-delete and
  no-rollback-on-conflict tests depend on it
- Seed the root user in the fake when a test needs root self-rotation to
  find it (`fake.users["vault-root"] = &fakeUser{Password: "root-pass-1"}`)
  — the root account pre-exists by definition, so this is the one
  legitimate pre-seed

## Table-Driven Method Tests

One test function per scenario row; table cases inside:

```go
func TestInitialize_Validation(t *testing.T) {
    cases := []struct {
        name    string
        mutate  func(map[string]interface{})
        wantErr string // substring naming the FIELD
    }{
        {"missing username", func(c map[string]interface{}) { delete(c, "username") }, "username is required"},
        {"missing password", func(c map[string]interface{}) { delete(c, "password") }, "password is required"},
        {"bad template", func(c map[string]interface{}) { c["username_template"] = "{{ .Nope" }, "username_template"},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            db, fake := newTestDB(t)
            cfg := validConfig()
            tc.mutate(cfg)
            _, err := db.Initialize(context.Background(), dbplugin.InitializeRequest{Config: cfg})
            require.Error(t, err)
            require.Contains(t, err.Error(), tc.wantErr)
            require.NotContains(t, err.Error(), "root-pass-1") // never the value
            require.Empty(t, fake.configs, "client must not be built on invalid config")
        })
    }
}
```

`Initialize` happy path asserts: `resp.Config` equals the input map,
`resp.Config[dbplugin.SupportedCredentialTypesKey]` lists exactly the
designed types, `fake.pings == 1` with `VerifyConnection: true` and `0`
without, and the factory saw the decoded config.

## Lifecycle Transition Tests

- **Create**: `NewUser` → `resp.Username` matches the template shape
  (prefix, length limit, lowercase); `fake.users[resp.Username]` has the
  request password, parsed roles, and (if supported) expiration; response
  struct has no other populated field.
- **Create rollback**: `fake.failOn["CreateUser"] = errors.New("grant denied")`
  → error returned wraps "grant denied"; `fake.calls` shows
  `CreateUser:` followed by `DeleteUser:` for the same username (or the
  rollback statements when the request carried them).
- **Create conflict is never rolled back**: pre-seed the exact username the
  template will render (or use a fixed `username_template` in the config)
  → error wraps `ErrUserExists`; `fake.calls` has no `DeleteUser:` /
  `ExecuteStatements:` after the `CreateUser:`; `fake.users[name]` is
  unchanged.
- **Delete + idempotent**: delete, assert gone; delete again → `NoError`.
- **Password change**: `UpdateUser{Username: u, Password: &ChangePassword{NewPassword: "p2"}}`
  → `fake.users[u].Password == "p2"`.
- **Root self-rotation**: seed root in fake; rotate root username →
  `db.config.Password == "p2"`, `db.rawConfig["password"] == "p2"`,
  `fake.configs` last entry has `Password: "p2"` (client rebuilt with the
  new credential), and a subsequent `NewUser` still succeeds. Then call
  `Close()` and `Initialize` again with `db.rawConfig` — must succeed (the
  Vault re-Initialize sequence).
- **Expiration**: applied when supported (`fake.users[u].Expiration`
  updated), else `UpdateUser{Expiration: …}` returns an error containing
  "not supported".
- **Unsupported credential type**: `CredentialType: CredentialTypeRSAPrivateKey`
  → error before any target call (`fake.calls` empty).
- **Not initialized**: fresh `newTestDB` without `Initialize` → every
  operation returns `connutil.ErrNotInitialized`; `Type()` still works;
  `Close()` is nil.

## Sanitizer Test

The one test that exercises the production `New()` wrapping:

```go
func TestSanitizer_RedactsPassword(t *testing.T) {
    db, fake := newTestDB(t)
    mw := dbplugin.NewDatabaseErrorSanitizerMiddleware(db, db.secretValues)
    mustInitialize(t, db, validConfig(), false)

    fake.failOn["CreateUser"] = fmt.Errorf("auth failed for root-pass-1 at example.test")
    _, err := mw.NewUser(context.Background(), newUserReq("r"))
    require.Error(t, err)
    require.NotContains(t, err.Error(), "root-pass-1")
    require.Contains(t, err.Error(), "[password]")
}
```

Extend with one case per Secret=yes config field in design §3 — an
unredacted field is a P0.

## Conventions

- Test names: `TestInitialize_Validation`, `TestNewUser_Create`,
  `TestNewUser_RollbackOnFailure`, `TestUpdateUser_RootSelfRotation`,
  `TestDeleteUser_Idempotent`, `TestSanitizer_RedactsPassword` — matching
  design §3/§4 scenario tables 1:1
- Every test uses a fresh `newTestDB` — no shared mutable state;
  `t.Parallel()` where the fake is per-test
- `go test -race ./...` is the validation-time invocation; keep tests
  race-clean (the fake's mutex is not optional)
- Unit tests never talk to a live system. Env-gated acceptance tests
  against a disposable container are the separate, opt-in layer per
  `vault-dbplugin-integration-testing`
