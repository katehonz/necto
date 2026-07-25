## Web middleware / auth helpers tests

import std/[unittest, options]
import ../src/necto
import ../src/necto/web

suite "Web helpers":
  let secret = "this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345"
  let config = defaultAuthConfig(secret)

  test "extractBearerToken parses Authorization header":
    let t = extractBearerToken("Bearer abc.def.ghi")
    check(t.isSome)
    check(t.get == "abc.def.ghi")

  test "extractBearerToken is case-insensitive on Bearer":
    let t = extractBearerToken("bearer tok123")
    check(t.isSome)
    check(t.get == "tok123")

  test "extractBearerToken rejects missing prefix":
    check(extractBearerToken("Basic xyz").isNone)
    check(extractBearerToken("").isNone)
    check(extractBearerToken("Bearer ").isNone)

  test "authenticateBearer returns user id":
    let token = generateToken(config, "user-99")
    let uid = authenticateBearer(config, "Bearer " & token)
    check(uid.isSome)
    check(uid.get == "user-99")

  test "authenticateBearer rejects bad token":
    check(authenticateBearer(config, "Bearer not-a-jwt").isNone)
    check(authenticateBearer(config, "").isNone)

  test "newRequestContext wires auth and tenant":
    let token = generateToken(config, "u1")
    # repo can be nil for pure header parsing tests
    let ctx = newRequestContext(
      repo = nil,
      auth = config,
      authorizationHeader = "Bearer " & token,
      tenantId = "org-7",
      tenantSchema = "tenant_a"
    )
    check(ctx.userId.isSome)
    check(ctx.userId.get == "u1")
    check(ctx.tenantId.get == "org-7")
    check(ctx.tenantSchema.get == "tenant_a")

  test "withRequestScope sets and clears tenant id":
    let ctx = RequestContext(
      repo: nil,
      auth: config,
      userId: some("u1"),
      tenantId: some("tid-1"),
      tenantSchema: none(string)
    )
    withRequestScope(ctx):
      check(getQueryTenantId() == "tid-1")
    check(getQueryTenantId().len == 0)

  test "requireUser raises when missing":
    let ctx = RequestContext(repo: nil, auth: config, userId: none(string))
    expect UnauthorizedError:
      discard requireUser(ctx)

  test "requireUser returns id":
    let ctx = RequestContext(repo: nil, auth: config, userId: some("ok"))
    check(requireUser(ctx) == "ok")
