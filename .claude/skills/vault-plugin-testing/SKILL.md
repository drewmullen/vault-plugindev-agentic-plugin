---
name: vault-plugin-testing
description: Go test patterns for Vault secrets engine plugins — logical-backend test harness via HandleRequest, programmable fake clients, table-driven path tests, lifecycle transition coverage (issue/renew/revoke/rotate), WAL crash-safety tests, and enabled/disabled Enterprise-feature modes. Use when writing or reviewing secrets engine tests.
user-invocable: false
---

# Vault Secrets Engine Test Patterns

Unit and backend-harness tests only: every test runs against `logical.InmemStorage`
and a fake client. No test talks to a real external API (dockertest deferred).
testify (`require`/`assert`) is allowed and preferred for assertions.

## The TDD Boundary in Go

Tests drive the backend through `b.HandleRequest` with **string paths**, so
test files compile without referencing unimplemented handler symbols. The red
baseline is therefore:

- `go build ./...` and `go vet ./...` PASS (scaffold compiles)
- `go test ./...` FAILS — unimplemented paths return "unsupported path" /
  "unsupported operation" errors that the assertions catch

Write real test bodies from design §3/§4 scenario tables immediately; do not
stub with `t.Skip` unless a scenario is blocked on another scenario's storage
side effects (then `t.Skip("blocked on <item>")` with the checklist item named).

## Test Harness (`helpers_test.go`)

```go
func getTestBackend(tb testing.TB) (*exampleBackend, logical.Storage) {
    tb.Helper()
    config := logical.TestBackendConfig()
    config.StorageView = new(logical.InmemStorage)
    config.Logger = hclog.NewNullLogger()
    config.System = logical.TestSystemView() // or a custom testSystemView

    b, err := Factory(context.Background(), config)
    require.NoError(tb, err)

    eb := b.(*exampleBackend)
    eb.client = newFakeClient() // inject the fake at the client seam
    return eb, config.StorageView
}
```

Request helper shape (one per operation, reused by all tests):

```go
func testWrite(t *testing.T, b logical.Backend, s logical.Storage, path string,
    d map[string]interface{}) (*logical.Response, error) {
    t.Helper()
    return b.HandleRequest(context.Background(), &logical.Request{
        Operation: logical.UpdateOperation, // or Create/Read/Delete/List
        Path:      path,
        Data:      d,
        Storage:   s,
    })
}
```

Check both `err` and `resp.IsError()` — user errors arrive as error responses
with a nil Go error.

## Programmable Fake Client

One fake per repo in `helpers_test.go` (or `fake_client_test.go`),
implementing the production `Client` interface:

```go
type fakeClient struct {
    mu      sync.Mutex
    created []CreateTokenRequest        // capture calls for assertions
    tokens  map[string]bool             // observable external state
    failOn  map[string]error            // inject failures per method
}

func (f *fakeClient) CreateToken(ctx context.Context, r CreateTokenRequest) (*Token, error) {
    f.mu.Lock(); defer f.mu.Unlock()
    if err := f.failOn["CreateToken"]; err != nil { return nil, err }
    ...
}
```

Rules:

- Error injection per method (`failOn`) so every failure path in design §2's
  error-semantics column gets a table case
- Call capture so tests assert WHAT was sent externally, not just the response
- Simulate idempotency semantics: deleting an absent credential returns the
  same not-found the real API returns — revoke tests depend on it

## Table-Driven Path Tests

One test function per path family (`TestConfig_*`, `TestRoles_*`, ...), table
cases covering: happy CRUD(+list), validation rejections (expect
`resp.IsError()` with actionable message), and secret-omission checks:

```go
resp, err := testRead(t, b, s, "config")
require.NoError(t, err)
require.NotContains(t, resp.Data, "token") // read never returns secrets
```

For hierarchical layouts, include: child operations against a missing parent
fail with an error response; deleting a parent with children behaves per
design §3.

## Lifecycle Transition Tests

Every transition from design §4's scenario table:

- **Issue**: read `creds/<name>` → assert `resp.Secret` TTLs and that
  `resp.Data` contains exactly the §3-declared fields
- **Renew**: `logical.RenewOperation` request with `req.Secret` carrying the
  issued secret's `InternalData`; assert TTL handling
- **Revoke**: `logical.RevokeOperation` the same way; assert the fake shows
  external deletion; repeat with the credential already gone → still succeeds
- **Rotate**: call the rotation endpoint; assert ordering via the fake's
  capture (external call before storage read-back shows new value)
- **Rotation failure / WAL**: inject failure after the external call; assert a
  WAL entry exists (`framework.ListWAL`); run the rollback/tidy path; assert
  recovery per design §4

## Enterprise-Dependent Feature Modes

Each feature gets both modes:

- **Disabled (default)**: config write with no rotation schedule → no
  registration attempted (fake/system-view records none); manual rotation
  works
- **Enabled**: a `testSystemView` that records rotation-job
  registration/deregistration calls; config write with a schedule → asserts
  registration request fields; config delete/disable → deregistration

## Conventions

- Test names: `TestConfig_Write`, `TestRoles_CRUD`, `TestCreds_Issue`,
  `TestRotate_WALRecovery` — matching design §3/§4 scenario tables 1:1
- Every test uses a fresh `getTestBackend` — no shared mutable state;
  parallel-safe where possible
- `go test -race ./...` is the validation-time invocation; keep tests race-clean
- Acceptance tests against live systems are NOT written by these workflows;
  live verification happens via the validator's optional `vault server -dev`
  smoke mount
