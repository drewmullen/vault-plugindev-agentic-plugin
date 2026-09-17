---
name: vault-dbplugin-architecture
description: Vault database plugin core architecture — the dbplugin v5 Database interface, plugin struct, New() factory with error-sanitizer middleware, client seam with injectable factory, method stubs for the red baseline, ServeMultiplex entry point, PluginVersion, and repo scaffold. Activity-specific patterns (Initialize/config, NewUser/DeleteUser, UpdateUser/rotation) live in the vault-dbplugin-* activity skills. Use when scaffolding database.go, client.go, main.go, or wiring a new method.
user-invocable: false
---

# Vault Database Plugin Architecture Patterns

Core scaffold patterns for `dbplugin.Database` (v5) plugins on the public
`github.com/hashicorp/vault/sdk`. The constitution defines what is
mandatory; this skill shows how the skeleton fits together. Per-activity
code lives in dedicated skills — see the activity map at the end.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-database-*`
repos, the in-tree `plugins/database/*`, local checkouts). Web research is
for the *target system's* admin API only. The examples use a generic
`example` target; substitute the plugin's own names, fields, and client
operations from design §2/§3.

## The Division of Labor

```
operator ──► vault database/ engine (core) ──gRPC──► this plugin ──► target DB
             paths, leases, password gen,             Initialize / NewUser /
             rotation schedule, WAL, Enterprise       UpdateUser / DeleteUser
```

The plugin has no paths, no storage, no leases, no WAL. It receives fully
formed requests (password already generated, expiration already computed,
statements already looked up from the role) and executes them against the
target through one narrow client interface.

## Plugin Struct & Factory (`database.go`)

```go
package exampledb

const (
    exampleTypeName = "example"
    // Rendered with dbplugin.UsernameMetadata{DisplayName, RoleName}.
    defaultUserNameTemplate = `{{ printf "v-%s-%s-%s-%s" (.DisplayName | truncate 8) (.RoleName | truncate 8) (random 20) (unix_time) | truncate 63 }}`

    // Target facts the activity skills key on — values come from design §3
    // (Username Generation) and §4 (Expiration). Declared once, here.
    maxUsernameLength    = 63
    targetSupportsExpiry = true
)

// Compile-time interface check.
var _ dbplugin.Database = (*ExampleDB)(nil)

type ExampleDB struct {
    mu sync.RWMutex

    config    exampleConfig          // decoded, validated
    rawConfig map[string]interface{} // exactly what Vault passed (echoed back, mutated on self-rotation)
    usernameProducer template.StringTemplate

    client    Client                                    // the ONLY seam to the target
    newClient func(exampleConfig) (Client, error)       // injectable factory — tests override
    initialized bool

    log hclog.Logger // identifiers only — never statements or secrets
}

// New is the factory dbplugin.ServeMultiplex calls per connection. The
// sanitizer middleware redacts every secretValues() entry from error text.
func New() (interface{}, error) {
    db := newExampleDB()
    return dbplugin.NewDatabaseErrorSanitizerMiddleware(db, db.secretValues), nil
}

func newExampleDB() *ExampleDB {
    return &ExampleDB{
        newClient: newHTTPClient, // production factory; tests swap it
        log:       hclog.New(&hclog.LoggerOptions{Name: exampleTypeName}),
    }
}

// logger is what the activity skills call; nil-safe so a zero-value struct
// in a test never panics on a log line.
func (d *ExampleDB) logger() hclog.Logger {
    if d.log == nil {
        return hclog.NewNullLogger()
    }
    return d.log
}

func (d *ExampleDB) Type() (string, error) { return exampleTypeName, nil }

func (d *ExampleDB) PluginVersion() logical.PluginVersion {
    return logical.PluginVersion{Version: version} // var version = "v0.1.0" set via -ldflags
}
```

- `rawConfig` is kept because Vault persists `InitializeResponse.Config` as
  `connection_details` and re-sends it on the next `Initialize`; the
  rotation activity mutates its `password` key on root self-rotation.
- `newClient` is a struct field, not a package var, so parallel tests never
  race on it.
- The bodies of `Initialize`, `Close`, `secretValues` are in
  `vault-dbplugin-connection`; `NewUser`/`DeleteUser` in
  `vault-dbplugin-users`; `UpdateUser` in `vault-dbplugin-rotation`.

## Client Seam (`client.go`)

```go
// Client is the narrow interface every method uses. One method per
// target operation design §2 lists — nothing more.
type Client interface {
    Ping(ctx context.Context) error
    CreateUser(ctx context.Context, req CreateUserRequest) error
    SetPassword(ctx context.Context, username, password string) error
    SetExpiration(ctx context.Context, username string, expiresAt time.Time) error // omit if targetSupportsExpiry is false
    DeleteUser(ctx context.Context, username string) error // returns ErrUserNotFound when absent
    // ExecuteStatements runs operator-supplied statements (rollback,
    // revocation, rotation, renew) with {{name}}/{{username}}/{{password}}/
    // {{expiration}} substituted from data. SQL targets run them in one
    // transaction; omit when design §3 declares no operator statement sets.
    ExecuteStatements(ctx context.Context, stmts []string, data map[string]string) error
    Close() error
}

type CreateUserRequest struct {
    Username   string
    Password   string
    Roles      []string
    Expiration time.Time // zero when not applicable
}

// Sentinel errors the concrete client translates target responses into
// (HTTP 404/409, SQL "does not exist"/"already exists") — in ONE place, so
// methods branch on errors.Is instead of string matching.
var (
    ErrUserNotFound = errors.New("user not found") // DeleteUser: idempotent success
    ErrUserExists   = errors.New("user already exists") // NewUser: never roll back — the user is not ours
)
```

SQL targets: the concrete client wraps `*sql.DB` obtained from
`connutil.SQLConnectionProducer`; the interface is unchanged. Statement
execution belongs to the client's `ExecuteStatements` (see
`vault-dbplugin-users` for the transactional body) so handlers never touch
`database/sql` directly.

The names above (`Client` methods, `CreateUserRequest`, `ErrUserNotFound`,
`ErrUserExists`, `maxUsernameLength`, `targetSupportsExpiry`, `logger()`) are the shared
vocabulary of every `vault-dbplugin-*` skill and of the test fake — keep
them verbatim so the pieces compile together.

## Red-Baseline Stubs (test-writer scaffold)

Every interface method exists from the first commit so tests compile:

```go
var errNotImplemented = errors.New("not implemented")

func (d *ExampleDB) Initialize(ctx context.Context, req dbplugin.InitializeRequest) (dbplugin.InitializeResponse, error) {
    return dbplugin.InitializeResponse{}, errNotImplemented
}
// ... NewUser, UpdateUser, DeleteUser, Close likewise; Type() is real.
```

Developer items replace the stub bodies file by file; `Type()` and the
struct are real from the start.

## Entry Point (`cmd/vault-plugin-database-<name>/main.go`)

```go
package main

func main() {
    if err := run(); err != nil {
        hclog.New(&hclog.LoggerOptions{}).Error("plugin shutting down", "error", err)
        os.Exit(1)
    }
}

func run() error {
    // Multiplexed: one process serves every database/config/<name> that
    // names this plugin; Vault calls New() per connection.
    dbplugin.ServeMultiplex(exampledb.New)
    return nil
}
```

`ServeMultiplex` handles the plugin handshake, TLS, and the gRPC server —
there is no `api.VaultPluginTLSProvider` wiring as in secrets engines.

## Known SDK Gotchas

1. **Errors flatten across gRPC.** `errors.Is(err, ErrUserNotFound)` works
   inside the plugin only. Swallow not-found *inside* `DeleteUser`; never
   expect Vault to interpret it.
2. **Empty secretValues keys corrupt redaction.** Skip empty strings when
   building the map — before `Initialize` there is no password.
3. **`InitializeResponse.Config` is persisted.** Return the request map (or
   a copy with defaults filled). Returning `nil` wipes `connection_details`
   and the next `Initialize` fails.
4. **`SetSupportedCredentialTypes` is required** for anything beyond
   password; Vault defaults to password-only when the key is absent.
5. **`VerifyConnection=false` still constructs the client** — it only skips
   the round-trip. Do not treat it as "lazy init".
6. **Username templates render with `UsernameMetadata`**, whose fields are
   `DisplayName` and `RoleName`; `random`, `truncate`, `unix_time`,
   `lowercase` are the usual helpers. Test-render at `Initialize` so a bad
   template fails config, not the first creds read.

## Repo Scaffold

- `go.mod`: module `github.com/{org}/vault-plugin-database-{name}`, Go >=
  1.24, deps per constitution §5, no `replace` directives.
- `Makefile`: `build` (CGO_ENABLED=0 into `bin/`), `test` (`go test -race
  ./...`), `fmt`, `vet`, and `dev` that builds into a `vault server -dev
  -dev-plugin-dir` directory and prints the register/enable commands.
- `README.md`: register (`vault plugin register -sha256=… database
  vault-plugin-database-{name}`), `vault secrets enable database`, a
  `config/<name>` example with every §3 field, a `roles/<name>` example
  with the statement format, and the root-account least-privilege list from
  design §5.

## Activity Skill Map

Each design §6 checklist item names the activity skill(s) it needs; load
them before implementing that item's files.

| Activity | Files | Skill |
|---|---|---|
| Initialize, config decode, client seam, Close, secretValues | `database.go`, `client.go` | `vault-dbplugin-connection` |
| NewUser, DeleteUser, statements, username generation | `users.go` | `vault-dbplugin-users` |
| UpdateUser: password / expiration / public key, root self-rotation | `rotation.go` | `vault-dbplugin-rotation` |
| Integration harness | `docker-compose.test.yml`, `acceptance_test.go` | `vault-dbplugin-integration-testing` |
