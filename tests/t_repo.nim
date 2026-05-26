## Тестове за Repo и PostgreSQL връзка

import std/[unittest, os, strutils, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

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
