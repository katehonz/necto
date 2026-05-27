## Тестове за NectoMulti — композируеми транзакции

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema MultiUser:
  table "test_multi_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  timestamps

necto_schema MultiProfile:
  table "test_multi_profiles"
  field id: int64 {.primary_key, auto_increment.}
  field bio: string
  field user_id: int64
  timestamps

suite "NectoMulti composable transactions":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_multi_profiles")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_multi_users")
    testrepoInstance.exec("""
      CREATE TABLE test_multi_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_multi_profiles (
        id BIGSERIAL PRIMARY KEY,
        bio TEXT,
        user_id BIGINT REFERENCES test_multi_users(id),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_multi_profiles")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_multi_users")

  test "Basic insert multi succeeds":
    var cs = newChangeset(newMultiUser(), {"name": "Alice", "email": "alice@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])

    let multi = newMulti().insert("user", cs)
    let ctx = testrepoInstance.transactionMulti(multi)

    check(ctx.hasKey("user"))
    let user = cast[MultiUser](ctx["user"])
    check(user.name == "Alice")
    check(user.id > 0)

  test "Multi with insert and update":
    var cs = newChangeset(newMultiUser(), {"name": "Bob", "email": "bob@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])
    let inserted = testrepoInstance.insert(cs)

    var updCs = newChangeset(inserted, {"name": "Robert", "email": "robert@test.com"}.toTable)
    updCs = updCs.castFields(@["name", "email"])

    let multi = newMulti().update("user", updCs)
    let ctx = testrepoInstance.transactionMulti(multi)

    let user = cast[MultiUser](ctx["user"])
    check(user.name == "Robert")

  test "Multi rollback on failure":
    # Insert a user first to cause unique constraint
    var cs1 = newChangeset(newMultiUser(), {"name": "Conflict", "email": "conflict@test.com"}.toTable)
    cs1 = cs1.castFields(@["name", "email"])
    discard testrepoInstance.insert(cs1)

    # Add unique constraint
    testrepoInstance.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_multi_user_name ON test_multi_users(name)")

    # Try to insert duplicate — should fail
    var cs2 = newChangeset(newMultiUser(), {"name": "Conflict", "email": "other@test.com"}.toTable)
    cs2 = cs2.castFields(@["name", "email"])

    let multi = newMulti().insert("user", cs2)
    var raised = false
    try:
      discard testrepoInstance.transactionMulti(multi)
    except RollbackError:
      raised = true
    except CatchableError:
      raised = true

    check(raised)

    # Verify nothing was inserted
    let count = testrepoInstance.scalar("SELECT COUNT(*) FROM test_multi_users WHERE email = 'other@test.com'")
    check(count == "0")

    testrepoInstance.exec("DROP INDEX IF EXISTS idx_multi_user_name")

  test "Multi dependency validation catches missing dependency":
    var cs = newChangeset(newMultiUser(), {"name": "DepTest"}.toTable)
    cs = cs.castFields(@["name"])

    let multi = newMulti().insert("profile", cs, dependsOn = @["user"])
    var raised = false
    try:
      multi.validateDependencies()
    except ValueError:
      raised = true
    check(raised)

  test "Multi run custom step":
    var cs = newChangeset(newMultiUser(), {"name": "Custom", "email": "custom@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])

    var customCalled = false
    let multi = newMulti()
      .insert("user", cs)
      .run("verify") do (repo: Repo, ctx: MultiContext) -> (pointer, string):
        customCalled = true
        let user = cast[MultiUser](ctx["user"])
        if user.id > 0:
          (nil, "")
        else:
          (nil, "Invalid user id")

    discard testrepoInstance.transactionMulti(multi)
    check(customCalled)

  test "Multi delete step":
    var cs = newChangeset(newMultiUser(), {"name": "ToDelete", "email": "del@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])
    let user = testrepoInstance.insert(cs)

    var delCs = newChangeset(user)
    delCs = delCs.putChange("id", $user.id)
    let multi = newMulti().delete("user", delCs)
    discard testrepoInstance.transactionMulti(multi)

    let remaining = testrepoInstance.scalar("SELECT COUNT(*) FROM test_multi_users WHERE id = " & $user.id)
    check(remaining == "0")
