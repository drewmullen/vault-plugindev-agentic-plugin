---
name: vault-plugin-dynamic-roles
description: Vault secrets engine dynamic-role CRUD patterns — role entry struct with versioning, framework.Path builders, existence checks, read/write/delete/list handlers, storage helpers, and validate-in-write rules. Use when implementing path_roles.go (role templates for minting dynamic credentials).
user-invocable: false
---

# Dynamic Role CRUD

A dynamic role is a *template* for minting credentials: it names the scope,
TTLs, and target-system parameters that `creds/<name>` will use. This
activity is self-contained in `path_roles.go` — the one path family whose
skeleton does not span files. The field set diverges per engine (design §3
declares it); the CRUD skeleton below does not.

**This skill is self-contained.** Implement from the examples below — do NOT
read or fetch other plugin codebases (GitHub `vault-plugin-*` repos, local
checkouts). Web research is for the *target system's* API only. The examples
use a generic `example` engine; substitute the engine's own names, fields,
and client operations from design §2/§3.

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

## Rules

- Validation rules (`logical.ErrorResponse` + nil error for user mistakes)
  belong in the write handler, before anything persists. The TTL ≤ MaxTTL
  check above is the canonical example; add the engine's own field
  validations (scope enums, mutually exclusive discriminators) in the same
  place.
- Engine-specific fields follow the same `GetOk` shape: apply when present,
  fall back to a default only on `CreateOperation`, reject invalid
  combinations before `setRole`.
- The `Version` field is the storage-schema escape hatch: bump it when the
  entry shape changes and handle old versions explicitly on read.
- Roles that manage a *pre-existing* external account (username +
  rotation_period rather than a minting template) are static roles — a
  different activity with different coupling; see
  `vault-plugin-static-roles`.
