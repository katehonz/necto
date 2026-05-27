## Necto Auth Module
##
## Password hashing (bcrypt via checksums) + JWT tokens for authentication.
##
## Requires: `jwt` and `checksums` nimble packages.

import std/[tables, times, options, json]
import jwt
import checksums/bcrypt

export tables, times, options

type
  AuthConfig* = object
    secret*: string
    algorithm*: SignatureAlgorithm
    tokenTtl*: TimeInterval
    issuer*: string

proc defaultAuthConfig*(secret: string): AuthConfig =
  ## Creates a default auth config with HS256 and 24h token TTL.
  ## secret must be at least 32 bytes for HMAC.
  AuthConfig(
    secret: secret,
    algorithm: HS256,
    tokenTtl: hours(24),
    issuer: "necto"
  )

# --- Password hashing (bcrypt via checksums) ---

proc hashPassword*(password: string, rounds: int = 10): string =
  ## Hashes a password with bcrypt. Returns the full hash string (salt + hash).
  let salt = generateSalt(max(4, min(31, rounds)).CostFactor)
  result = $bcrypt(password, salt)

proc verifyPassword*(password: string, hash: string): bool =
  ## Verifies a password against a bcrypt hash.
  result = verify(password, hash)

# --- JWT token generation ---

proc generateToken*(config: AuthConfig, userId: string,
                    extraClaims: Table[string, string] = initTable[string, string]()): string =
  ## Generates a signed JWT token with `sub` = userId, `iss`, `iat`, `exp`.
  let header = %*{"alg": $config.algorithm, "typ": "JWT"}

  var claims = newTable[string, Claim]()
  claims["sub"] = newStringClaim(userId)
  claims["iss"] = newStringClaim(config.issuer)
  claims["iat"] = newTimeClaim(getTime())
  claims["exp"] = newTimeClaim(getTime() + config.tokenTtl)

  for k, v in extraClaims:
    claims[k] = newStringClaim(v)

  var token = initJWT(header, claims)
  token.sign(config.secret)
  result = token.toString

proc verifyToken*(config: AuthConfig, tokenStr: string): Option[JWT] =
  ## Verifies a JWT token signature, algorithm and time claims.
  ## Returns none if invalid or expired.
  try:
    let token = toJWT(tokenStr)
    if not token.verify(config.secret, config.algorithm):
      return none(JWT)
    return some(token)
  except CatchableError:
    return none(JWT)

proc tokenUserId*(token: JWT): Option[string] =
  ## Extracts the `sub` claim (user ID) from a verified token.
  if token.claims.hasKey("sub"):
    return some(token.claims["sub"].node.getStr)
  return none(string)

proc tokenClaim*(token: JWT, key: string): Option[string] =
  ## Extracts a string claim from a verified token.
  if token.claims.hasKey(key):
    return some(token.claims[key].node.getStr)
  return none(string)

proc tokenExpiry*(token: JWT): Option[Time] =
  ## Extracts the `exp` claim from a verified token.
  if token.claims.hasKey("exp"):
    return some(token.claims["exp"].getClaimTime)
  return none(Time)
