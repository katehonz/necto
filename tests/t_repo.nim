## Тестове за Repo и PostgreSQL връзка

import std/[unittest, os, strutils, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema RepoUser:
  table "test_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  field age: int

suite "Repo connection":
  test "TestRepo is defined":
    check(testrepoInstance != nil)
    check(testrepoInstance.adapter != nil)

  test "Adapter configuration is correct":
    let pg = PostgresAdapter(testrepoInstance.adapter)
    check(pg.host == "localhost")
    check(pg.user == "postgres")
    check(pg.database == "necto_test")
    check(pg.poolSize == 5)

  test "Can execute raw SQL in transaction":
    testrepoInstance.transaction do ():
      testrepoInstance.exec("SELECT 1")

  test "Transaction rolls back on exception":
    var raised = false
    try:
      testrepoInstance.transaction do ():
        testrepoInstance.exec("SELECT 1")
        raise newException(ValueError, "intentional")
    except ValueError:
      raised = true
    check(raised)

suite "Repo CRUD integration":
  setup:
    # Създаваме тестова таблица
    testrepoInstance.exec("""
      DROP TABLE IF EXISTS test_users
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        age INTEGER,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_users")

  test "Insert and select via raw SQL":
    testrepoInstance.exec(
      "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
      @["Ivan", "ivan@test.com", "30"]
    )
    let rows = testrepoInstance.queryRaw(
      "SELECT name, email, age FROM test_users WHERE name = $1",
      @["Ivan"]
    )
    check(rows.len == 1)
    check(rows[0][0] == "Ivan")
    check(rows[0][1] == "ivan@test.com")
    check(rows[0][2] == "30")

  test "Scalar returns single value":
    testrepoInstance.exec(
      "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
      @["Maria", "maria@test.com", "25"]
    )
    let count = testrepoInstance.scalar(
      "SELECT COUNT(*) FROM test_users WHERE age > $1",
      @["20"]
    )
    check(count == "1")

  test "Pool metrics are tracked":
    let before = testrepoInstance.poolMetrics()
    check(before.totalRequests >= 0)

    # Trigger some pool activity
    for i in 1..3:
      discard testrepoInstance.scalar("SELECT $1", @[$i])

    let after = testrepoInstance.poolMetrics()
    check(after.totalRequests > before.totalRequests)
    check(after.totalWaitMs >= 0)
    check(after.maxWaitMs >= 0)
    check(after.peakActiveConns >= 0)
    check(after.availableConns >= 0)

  test "Transaction rollback removes inserted data":
    testrepoInstance.transaction:
      testrepoInstance.exec(
        "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
        @["RollbackTest", "rollback@test.com", "99"]
      )
      testrepoInstance.rollback()

    let count = testrepoInstance.scalar(
      "SELECT COUNT(*) FROM test_users WHERE name = $1",
      @["RollbackTest"]
    )
    check(count == "0")

  test "Savepoint allows partial rollback":
    testrepoInstance.transaction:
      testrepoInstance.exec(
        "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
        @["SavepointOuter", "outer@test.com", "10"]
      )
      var spFailed = false
      try:
        testrepoInstance.savepoint("sp1"):
          testrepoInstance.exec(
            "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
            @["SavepointInner", "inner@test.com", "20"]
          )
          raise newException(ValueError, "Simulated failure")
      except ValueError:
        spFailed = true
      check(spFailed)

    # Outer insert should survive, inner should not
    let outerCount = testrepoInstance.scalar(
      "SELECT COUNT(*) FROM test_users WHERE name = $1",
      @["SavepointOuter"]
    )
    check(outerCount == "1")

    let innerCount = testrepoInstance.scalar(
      "SELECT COUNT(*) FROM test_users WHERE name = $1",
      @["SavepointInner"]
    )
    check(innerCount == "0")

  test "inTransaction returns correct state":
    check(not testrepoInstance.inTransaction())
    testrepoInstance.transaction:
      check(testrepoInstance.inTransaction())

  test "Upsert doNothing ignores duplicate":
    testrepoInstance.exec(
      "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
      @["UpsertDup", "dup@test.com", "50"]
    )
    testrepoInstance.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_test_user_email ON test_users(email)")

    var cs = newChangeset(newRepoUser(), {"name": "UpsertDup2", "email": "dup@test.com", "age": "60"}.toTable)
    cs = cs.castFields(@["name", "email", "age"])

    let result = testrepoInstance.insert(cs, doNothing())
    check(result.id == 0)  # DO NOTHING - няма insert

    # Original record unchanged
    let original = testrepoInstance.scalar("SELECT age FROM test_users WHERE email = $1", @["dup@test.com"])
    check(original == "50")

    testrepoInstance.exec("DROP INDEX IF EXISTS idx_test_user_email")

  test "Upsert doUpdate updates existing":
    testrepoInstance.exec(
      "INSERT INTO test_users (name, email, age) VALUES ($1, $2, $3)",
      @["UpsertUpdate", "update@test.com", "70"]
    )
    testrepoInstance.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_test_user_email2 ON test_users(email)")

    var cs = newChangeset(newRepoUser(), {"name": "UpsertUpdateNew", "email": "update@test.com", "age": "80"}.toTable)
    cs = cs.castFields(@["name", "email", "age"])

    let result = testrepoInstance.insert(cs, doUpdate("email", @["name", "age"]))
    check(result.name == "UpsertUpdateNew")
    check(result.age == 80)

    testrepoInstance.exec("DROP INDEX IF EXISTS idx_test_user_email2")
