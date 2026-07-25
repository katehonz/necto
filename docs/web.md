# Auth & Web Helpers

Necto ships with a small auth module and framework-agnostic HTTP helpers.

```nim
import necto   # exports auth + web
```

## Passwords & JWT

```nim
let hash = hashPassword("s3cret")
assert verifyPassword("s3cret", hash)

let cfg = defaultAuthConfig("at-least-32-bytes-secret-key-here!!")
let token = generateToken(cfg, "user-42", {"role": "admin"}.toTable)
let jwt = verifyToken(cfg, token)
if jwt.isSome:
  echo tokenUserId(jwt.get)   # some("user-42")
  echo tokenClaim(jwt.get, "role")
```

## Bearer tokens

```nim
let uid = authenticateBearer(cfg, request.headers.getOrDefault("Authorization"))
# Option[string] — user id from `sub` claim
```

## Request context & tenant scope

```nim
let ctx = newRequestContext(
  repo = appRepo,
  auth = cfg,
  authorizationHeader = req.getHeader("Authorization"),
  tenantId = req.getHeader("X-Tenant-Id"),
  tenantSchema = req.getHeader("X-Tenant-Schema")
)

withRequestScope(ctx):
  let userId = requireUser(ctx)   # raises UnauthorizedError if missing
  let posts = ctx.repo.all(fromSchema(Post))  # tenant filters applied
```

`withRequestScope` always clears thread-local tenant state in `finally`.

## Framework notes

These helpers intentionally take plain strings so they work with:

- **Jester** — `request.headers["Authorization"]`
- **Prologue** — `ctx.getHeader("Authorization")`
- **Mummy** — `request.headers["Authorization"]`
- custom servers

No framework package is required.
