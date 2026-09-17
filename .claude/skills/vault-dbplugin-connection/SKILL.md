---
name: vault-dbplugin-connection
description: Vault database plugin connection seam — Initialize with mapstructure config decode and field validation, username-template compilation with test render, injectable client factory, VerifyConnection ping, InitializeResponse config echo + SetSupportedCredentialTypes, secretValues for the sanitizer, Close, and the not-initialized guard. Use when implementing database.go or client.go.
user-invocable: false
---

# Connection & Config (`Initialize`, `Close`, `secretValues`)

`Initialize` is the plugin's only configuration entry point: Vault calls it
on `config/<name>` write (with `VerifyConnection` from the operator's
`verify_connection` flag) and again on every fresh connection with the
persisted `connection_details`. It must be repeatable and side-effect free
beyond building a client.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases. Web research is for the *target
system's* admin API only.

## Config Struct

```go
type exampleConfig struct {
    URL              string `mapstructure:"connection_url"`
    Username         string `mapstructure:"username"`
    Password         string `mapstructure:"password"`
    UsernameTemplate string `mapstructure:"username_template"`
    CACert           string `mapstructure:"ca_cert"`
    InsecureTLS      bool   `mapstructure:"insecure_tls"`
    // Add fields ONLY from design §3 Config Fields — same names, same types.
}
```

Tags are the operator-facing names. Vault has already stripped its own
fields (`plugin_name`, `allowed_roles`, `verify_connection`,
`password_policy`, `root_rotation_statements`, rotation scheduling) — do not
declare them.

## Initialize

```go
func (d *ExampleDB) Initialize(ctx context.Context, req dbplugin.InitializeRequest) (dbplugin.InitializeResponse, error) {
    d.mu.Lock()
    defer d.mu.Unlock()

    var cfg exampleConfig
    if err := mapstructure.WeakDecode(req.Config, &cfg); err != nil {
        return dbplugin.InitializeResponse{}, fmt.Errorf("failed to decode config: %w", err)
    }
    // Validation names the field, never the value.
    switch {
    case cfg.URL == "":
        return dbplugin.InitializeResponse{}, errors.New("connection_url is required")
    case cfg.Username == "":
        return dbplugin.InitializeResponse{}, errors.New("username is required")
    case cfg.Password == "":
        return dbplugin.InitializeResponse{}, errors.New("password is required")
    }

    tmpl := cfg.UsernameTemplate
    if tmpl == "" {
        tmpl = defaultUserNameTemplate
    }
    up, err := template.NewTemplate(template.Template(tmpl))
    if err != nil {
        return dbplugin.InitializeResponse{}, fmt.Errorf("invalid username_template: %w", err)
    }
    // Test render: a template that parses but fails at render time must
    // fail config, not the first creds read.
    if _, err := up.Generate(dbplugin.UsernameMetadata{DisplayName: "test", RoleName: "test"}); err != nil {
        return dbplugin.InitializeResponse{}, fmt.Errorf("invalid username_template: %w", err)
    }

    client, err := d.newClient(cfg)
    if err != nil {
        return dbplugin.InitializeResponse{}, fmt.Errorf("failed to create client: %w", err)
    }
    if req.VerifyConnection {
        if err := client.Ping(ctx); err != nil {
            _ = client.Close()
            return dbplugin.InitializeResponse{}, fmt.Errorf("failed to verify connection: %w", err)
        }
    }

    // Replace any previous client (re-Initialize after rotate-root / reset).
    if d.client != nil {
        _ = d.client.Close()
    }
    d.config = cfg
    d.rawConfig = req.Config
    d.usernameProducer = up
    d.client = client
    d.initialized = true

    resp := dbplugin.InitializeResponse{Config: req.Config}
    resp.SetSupportedCredentialTypes([]dbplugin.CredentialType{
        dbplugin.CredentialTypePassword, // add others ONLY if design §3 marks them supported
    })
    return resp, nil
}
```

Rules:

- Decode → validate → template → client → optional ping → commit. Nothing
  is assigned to the struct until every step succeeds, so a failed
  re-Initialize leaves the previous working state intact.
- `req.Config` is echoed back verbatim. Vault stores it as
  `connection_details` and re-sends it. If you fill defaults, fill them
  into a **copy** and return that copy, never a map missing fields Vault
  passed in.
- `VerifyConnection` skips only the ping. The client is always built.

## Client Factory & Concrete Client

```go
func newHTTPClient(cfg exampleConfig) (Client, error) {
    tlsCfg, err := buildTLS(cfg) // CA / insecure per design §5
    if err != nil {
        return nil, err
    }
    return &httpClient{
        base: strings.TrimRight(cfg.URL, "/"),
        user: cfg.Username,
        pass: cfg.Password,
        http: &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{TLSClientConfig: tlsCfg}},
    }, nil
}
```

SQL variant — wrap the SDK producer behind the same interface:

```go
func newSQLClient(cfg exampleConfig) (Client, error) {
    p := &connutil.SQLConnectionProducer{}
    raw := map[string]interface{}{"connection_url": cfg.URL, "username": cfg.Username, "password": cfg.Password}
    if _, err := p.Init(context.Background(), raw, false); err != nil { // ping handled by our Ping()
        return nil, err
    }
    return &sqlClient{producer: p}, nil
}
```

The concrete client owns every driver/HTTP detail. Methods build requests
without ever placing credentials in URLs (basic auth header / body only).
Client error strings MUST NOT include request or response bodies.

## secretValues (sanitizer input)

```go
// secretValues feeds NewDatabaseErrorSanitizerMiddleware: every value here
// is replaced by its placeholder in any error the plugin returns.
func (d *ExampleDB) secretValues() map[string]string {
    d.mu.RLock()
    defer d.mu.RUnlock()
    out := map[string]string{}
    if d.config.Password != "" { // empty key would break redaction
        out[d.config.Password] = "[password]"
    }
    // one entry per Secret=yes field in design §3, e.g. client_key
    return out
}
```

The middleware calls this on **every** error, so it reflects the current
in-memory password even after a root self-rotation.

## Close & Guard

```go
func (d *ExampleDB) Close() error {
    d.mu.Lock()
    defer d.mu.Unlock()
    if d.client == nil {
        return nil // idempotent
    }
    err := d.client.Close()
    d.client = nil
    d.initialized = false
    return err
}

// borrow returns the live client under the read lock; callers defer the
// returned unlock. Every operation method starts here.
func (d *ExampleDB) borrow() (Client, func(), error) {
    d.mu.RLock()
    if !d.initialized || d.client == nil {
        d.mu.RUnlock()
        return nil, nil, connutil.ErrNotInitialized
    }
    return d.client, d.mu.RUnlock, nil
}
```

Vault calls `Close` after rotate-root and on `reset/<name>`; the next call
arrives after a fresh `Initialize`. Close must never wedge the process.

## Gotchas

- **Do not cache the password anywhere but `config` + `rawConfig`.** The
  rotation activity updates both; a third copy silently keeps the old one.
- **Defaults into the response, not just the struct.** If the operator
  omitted `username_template` and you want the effective template visible
  in `config/<name>` reads, put it in the returned copy of the map.
- **`mapstructure.WeakDecode`** accepts JSON numbers/strings for ints/bools
  the way the Vault API delivers them; plain `Decode` fails on `"true"`.
