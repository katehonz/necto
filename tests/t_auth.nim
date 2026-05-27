## Тестове за Necto Auth Module (bcrypt + JWT)
import jwt

import std/[unittest, tables, times, options, strutils]
import ../src/necto/auth

suite "Auth Module":
  test "hashPassword generates valid bcrypt hash":
    let hash = hashPassword("mysecretpassword")
    check(hash.len > 0)
    check(hash.startsWith("$2"))

  test "verifyPassword with correct password":
    let hash = hashPassword("mysecretpassword")
    check(verifyPassword("mysecretpassword", hash) == true)

  test "verifyPassword with wrong password":
    let hash = hashPassword("mysecretpassword")
    check(verifyPassword("wrongpassword", hash) == false)

  test "generateToken creates signed JWT":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let token = generateToken(config, "user-42")
    check(token.len > 0)
    check(token.count(".") == 2)  # header.claims.signature

  test "verifyToken with valid token":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let token = generateToken(config, "user-42")
    let verified = verifyToken(config, token)
    check(verified.isSome)

  test "verifyToken with invalid secret":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let token = generateToken(config, "user-42")
    let badConfig = defaultAuthConfig("wrong-secret")
    let verified = verifyToken(badConfig, token)
    check(verified.isNone)

  test "verifyToken with tampered token":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let token = generateToken(config, "user-42")
    let tampered = token & "x"
    let verified = verifyToken(config, tampered)
    check(verified.isNone)

  test "tokenUserId extracts sub claim":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let token = generateToken(config, "user-42")
    let verified = verifyToken(config, token).get()
    let userId = tokenUserId(verified)
    check(userId.isSome)
    check(userId.get() == "user-42")

  test "tokenClaim extracts custom claim":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    var extra = initTable[string, string]()
    extra["role"] = "admin"
    let token = generateToken(config, "user-42", extra)
    let verified = verifyToken(config, token).get()
    let role = tokenClaim(verified, "role")
    check(role.isSome)
    check(role.get() == "admin")

  test "tokenExpiry is set correctly":
    let config = defaultAuthConfig("this-is-a-very-long-secret-key-for-testing-jwt-tokens-12345")
    let before = getTime()
    let token = generateToken(config, "user-42")
    let after = getTime()
    let verified = verifyToken(config, token).get()
    let exp = tokenExpiry(verified)
    check(exp.isSome)
    # Expiry should be roughly 24 hours from now
    let expectedMin = before + hours(23)
    let expectedMax = after + hours(25)
    check(exp.get() > expectedMin)
    check(exp.get() < expectedMax)

  test "expired token is rejected":
    let config = AuthConfig(
      secret: "another-very-long-secret-key-for-auth-tests",
      algorithm: HS256,
      tokenTtl: seconds(-1),  # Already expired
      issuer: "necto"
    )
    let token = generateToken(config, "user-42")
    let verified = verifyToken(config, token)
    check(verified.isNone)

  test "defaultAuthConfig has expected defaults":
    let config = defaultAuthConfig("secret")
    check(config.secret == "secret")
    check(config.algorithm == HS256)
    check(config.issuer == "necto")
