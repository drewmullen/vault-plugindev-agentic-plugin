---
name: vault-plugin-dynamic-creds
description: Vault secrets engine dynamic credential patterns — creds path, framework.Secret lease definition, Response/InternalData discipline, renew and idempotent revoke callbacks, WAL-during-mint crash safety, and WAL rollback that revokes orphaned credentials. Use when implementing path_creds.go, secret_*.go, or the mint-side WAL.
user-invocable: false
---

# Dynamic Credentials (framework.Secret + WAL)

Minting is a triangle across three files: the `creds/<role>` path
(`path_creds.go`) calls the client and assembles the response, the
`framework.Secret` definition (`secret_<name>.go`) owns the renew/revoke
lifecycle, and the WAL (`wal.go`) covers the crash window between the
external create and the lease taking ownership. Implement all three
together — splitting the Secret from its mint site fractures the lease
lifecycle.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-*` repos, local
checkouts). Web research is for the *target system's* API only. The examples
use a generic `example` engine; substitute the engine's own names, fields,
and client operations from design §2/§3.

## Creds Path and Secret Definition

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
```

## Mint with WAL Safety Net

Ordering: external create → WAL the new credential's ID → build the leased
response → delete the WAL (the lease now owns revocation). If the request
dies between create and lease, the periodic WAL rollback revokes the
orphaned credential.

```go
const credsWALKey = "exampleTokenCreate"

type tokenWAL struct {
    Version   int       `json:"version"`
    TokenID   string    `json:"token_id"` // string: survives the WAL's JSON round-trip exactly
    RoleName  string    `json:"role_name"`
    CreatedAt time.Time `json:"created_at"`
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

    // WAL immediately after the external ID exists, BEFORE any further work
    // (verification calls, response assembly) that could fail.
    walID, err := framework.PutWAL(ctx, req.Storage, credsWALKey, &tokenWAL{
        Version:   1,
        TokenID:   token.ID,
        RoleName:  role.Name,
        CreatedAt: time.Now(),
    })
    if err != nil {
        // No WAL means no safety net — revoke now rather than orphan.
        _ = client.DeleteToken(ctx, token.ID)
        return nil, fmt.Errorf("error writing WAL entry: %w", err)
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

    // The lease now owns revocation; drop the WAL safety net. If this
    // delete fails the caller gets an error and no lease, so revoke rather
    // than hand out a credential whose WAL will later revoke it.
    if err := framework.DeleteWAL(ctx, req.Storage, walID); err != nil {
        _ = client.DeleteToken(ctx, token.ID)
        return nil, fmt.Errorf("failed to commit WAL for minted token: %w", err)
    }
    return resp, nil
}
```

- If the external system accepts a client-chosen ID or name, write the WAL
  BEFORE the create call instead — then no window exists at all.
- One window is irreducible when the server assigns the ID: the create
  commits but the response never reaches Vault. Mitigate by tagging created
  credentials with a unique request marker (e.g. in a description field) and
  sweeping matching orphans after ambiguous create failures.
- If the request context is already canceled when the create returns, revoke
  immediately (using a fresh context) instead of returning a lease the
  caller will never receive.

## Renew and Revoke

```go
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

## WAL Rollback

`WALRollback` (wired in the `framework.Backend` literal, with
`WALRollbackMinAge` ≥ 5 minutes so in-flight requests are not rolled back)
dispatches on the WAL kind. For the mint WAL the rollback is a revoke:
idempotent, so re-running a rollback — or rolling back a token already
cleaned up via its lease — is safe.

```go
func (b *exampleBackend) walRollback(ctx context.Context, req *logical.Request, kind string, data interface{}) error {
    switch kind {
    case credsWALKey:
        var wal tokenWAL
        if err := mapstructure.Decode(data, &wal); err != nil {
            return err
        }
        client, err := b.getClient(ctx, req.Storage)
        if err != nil {
            return err
        }
        return client.DeleteToken(ctx, wal.TokenID) // idempotent
    default:
        return fmt.Errorf("unknown WAL kind %q", kind)
    }
}
```

Every WAL kind the engine writes (mint, rotate-root, …) gets a case in this
one dispatcher. Never persist a credential the external system did not
accept; never lose track of one it did.
