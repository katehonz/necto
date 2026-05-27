## Тестове за CTE (Common Table Expressions)

import std/[unittest, os, strutils, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema CteUser:
  table "test_cte_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string

necto_schema CteOrder:
  table "test_cte_orders"
  field id: int64 {.primary_key, auto_increment.}
  field user_id: int64 {.not_null.}
  field total: int64

suite "CTE (WITH queries)":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_cte_users CASCADE")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_cte_orders")
    testrepoInstance.exec("""
      CREATE TABLE test_cte_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_cte_orders (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES test_cte_users(id),
        total BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_cte_orders")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_cte_users CASCADE")

  test "CTE generates valid SQL with renumbered placeholders":
    # Insert test data
    var ucs = newChangeset(newCteUser(), {"name": "Alice", "email": "a@test.com"}.toTable)
      .castFields(@["name", "email"])
    let alice = testrepoInstance.insert(ucs)
    ucs = newChangeset(newCteUser(), {"name": "Bob", "email": "b@test.com"}.toTable)
      .castFields(@["name", "email"])
    let bob = testrepoInstance.insert(ucs)

    var ocs = newChangeset(newCteOrder(), {"user_id": $alice.id, "total": "100"}.toTable)
      .castFields(@["user_id", "total"])
    discard testrepoInstance.insert(ocs)
    ocs = newChangeset(newCteOrder(), {"user_id": $alice.id, "total": "200"}.toTable)
      .castFields(@["user_id", "total"])
    discard testrepoInstance.insert(ocs)
    ocs = newChangeset(newCteOrder(), {"user_id": $bob.id, "total": "50"}.toTable)
      .castFields(@["user_id", "total"])
    discard testrepoInstance.insert(ocs)

    # CTE: user totals with sum
    let totals = fromSchema(CteOrder)
      .select("user_id")
      .sum("total", "total_spent")
      .groupBy("user_id")

    let q = fromSchema(CteUser)
      .withCte("user_totals", totals)

    let bq = q.toBoundQuery()
    check(bq.sql.contains("WITH"))
    check(bq.sql.contains("user_totals AS"))
    check(bq.sql.contains("SUM"))
    check(bq.sql.contains("GROUP BY"))

    # Verify the CTE runs (WITH ... SELECT FROM CTE users)
    let rows = testrepoInstance.queryRaw(bq.sql, bq.args)
    check(rows.len == 2)

  test "CTE with multiple CTEs generates valid SQL":
    let totals = fromSchema(CteOrder)
      .select("user_id")
      .sum("total", "total_spent")
      .groupBy("user_id")

    let bigSpenders = fromSchema(CteOrder)
      .select("user_id")
      .sum("total", "total_spent")
      .groupBy("user_id")
      .having("\"total_spent\"", Gte, "100")

    let q = fromSchema(CteUser)
      .withCte("user_totals", totals)
      .withCte("big_spenders", bigSpenders)

    let bq = q.toBoundQuery()
    check(bq.sql.contains("WITH user_totals AS"))
    check(bq.sql.contains("big_spenders AS"))
