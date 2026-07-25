## Necto Web helpers
##
## Framework-agnostic helpers for wiring Necto into HTTP apps
## (Jester, Prologue, Mummy, Karax backends, custom servers).
##
## Не зависи от конкретен web framework — работи с raw header strings.

import std/[strutils, options]
import ./auth
import ./repo
import ./query
import ./errors

export auth, errors

type
  RequestContext* = object
    ## Per-request scope: repo + auth + tenant.
    repo*: Repo
    auth*: AuthConfig
    userId*: Option[string]
    tenantId*: Option[string]      ## row-level tenant id
    tenantSchema*: Option[string]  ## PostgreSQL schema prefix

# --- Bearer token helpers ---

proc extractBearerToken*(authorizationHeader: string): Option[string] =
  ## Извлича token от `Authorization: Bearer <token>` header.
  ## Връща none при празен/невалиден header.
  let h = authorizationHeader.strip()
  if h.len == 0:
    return none(string)
  const prefix = "Bearer "
  if h.len > prefix.len and h[0 ..< prefix.len].cmpIgnoreCase(prefix) == 0:
    let token = h[prefix.len .. ^1].strip()
    if token.len > 0:
      return some(token)
  none(string)

proc authenticateBearer*(config: AuthConfig, authorizationHeader: string): Option[string] =
  ## Валидира Bearer JWT и връща user id (`sub` claim) или none.
  let tokenOpt = extractBearerToken(authorizationHeader)
  if tokenOpt.isNone:
    return none(string)
  let jwtOpt = verifyToken(config, tokenOpt.get)
  if jwtOpt.isNone:
    return none(string)
  tokenUserId(jwtOpt.get)

proc authenticateBearerToken*(config: AuthConfig, token: string): Option[string] =
  ## Валидира raw JWT string (без Bearer prefix) и връща user id.
  let jwtOpt = verifyToken(config, token)
  if jwtOpt.isNone:
    return none(string)
  tokenUserId(jwtOpt.get)

# --- Request scope (tenant + optional user) ---

proc applyScope*(ctx: RequestContext) =
  ## Прилага tenant schema / tenant id към thread-local query scope.
  if ctx.tenantSchema.isSome and ctx.tenantSchema.get.len > 0:
    setQueryTenant(ctx.tenantSchema.get)
  else:
    clearQueryTenant()
  if ctx.tenantId.isSome and ctx.tenantId.get.len > 0:
    setQueryTenantId(ctx.tenantId.get)
  else:
    clearQueryTenantId()

proc clearScope*() =
  ## Изчиства thread-local tenant scope.
  clearQueryTenant()
  clearQueryTenantId()

template withRequestScope*(ctx: RequestContext, body: untyped) =
  ## Изпълнява `body` с tenant scope; винаги clean-up-ва в finally.
  ##
  ## Пример (Jester-style):
  ##   let ctx = RequestContext(
  ##     repo: appRepo,
  ##     auth: authCfg,
  ##     userId: authenticateBearer(authCfg, request.headers.getOrDefault("Authorization")),
  ##     tenantId: some(request.headers.getOrDefault("X-Tenant-Id"))
  ##   )
  ##   withRequestScope(ctx):
  ##     let users = ctx.repo.all(fromSchema(User))
  applyScope(ctx)
  try:
    body
  finally:
    clearScope()

proc newRequestContext*(repo: Repo; auth: AuthConfig;
                        authorizationHeader = "";
                        tenantId = "";
                        tenantSchema = ""): RequestContext =
  ## Удобен конструктор: parse-ва Bearer token + tenant headers.
  result = RequestContext(
    repo: repo,
    auth: auth,
    userId: none(string),
    tenantId: if tenantId.len > 0: some(tenantId) else: none(string),
    tenantSchema: if tenantSchema.len > 0: some(tenantSchema) else: none(string)
  )
  if authorizationHeader.len > 0:
    result.userId = authenticateBearer(auth, authorizationHeader)

proc requireUser*(ctx: RequestContext): string =
  ## Връща user id или хвърля `UnauthorizedError`.
  if ctx.userId.isNone:
    raise newException(UnauthorizedError, "Unauthorized: missing or invalid bearer token")
  ctx.userId.get
