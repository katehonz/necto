## Тестове за subqueries (IN, EXISTS)

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema SubUser:
  table "test_sub_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}

necto_schema SubOrder:
  table "test_sub_orders"
  field id: int64 {.primary_key, auto_increment.}
  field user_id: int64 {.not_null.}
  field total: int64

suite "Subqueries":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_sub_orders")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_sub_users")
    testrepoInstance.exec("""
      CREATE TABLE test_sub_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_sub_orders (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL,
        total BIGINT
      )
    """)
    # Insert users
    for name in @["Alice", "Bob", "Charlie"]:
      testrepoInstance.exec("INSERT INTO test_sub_users (name) VALUES ($1)", @[name])
    # Insert orders: Alice (id=1) has 2 orders, Bob (id=2) has 1, Charlie (id=3) has 0
    testrepoInstance.exec("INSERT INTO test_sub_orders (user_id, total) VALUES ($1, $2)", @["1", "100"])
    testrepoInstance.exec("INSERT INTO test_sub_orders (user_id, total) VALUES ($1, $2)", @["1", "200"])
    testrepoInstance.exec("INSERT INTO test_sub_orders (user_id, total) VALUES ($1, $2)", @["2", "50"])

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_sub_orders")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_sub_users")

  test "whereIn with subquery":
    let sq = fromSchema(SubOrder).select("user_id")
      .where("total", Gt, "75")
      .subquery()
    let q = fromSchema(SubUser).whereIn("id", sq)
    let bq = q.toBoundQuery()
    check("\"id\" IN (SELECT \"user_id\" FROM \"test_sub_orders\" WHERE \"total\" > $1)" in bq.sql)
    check(bq.args == @["75"])

    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "Alice")  # Only Alice has orders > 75

  test "whereNotIn with subquery":
    let sq = fromSchema(SubOrder).select("user_id").subquery()
    let q = fromSchema(SubUser).whereNotIn("id", sq)
    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "Charlie")  # Charlie has no orders

  test "whereExists generates correct SQL":
    let sq = fromSchema(SubOrder).select("user_id").subquery()
    let q = fromSchema(SubUser).whereExists(sq)
    let bq = q.toBoundQuery()
    check("EXISTS (SELECT" in bq.sql)

  test "whereNotExists generates correct SQL":
    let sq = fromSchema(SubOrder).select("user_id").subquery()
    let q = fromSchema(SubUser).whereNotExists(sq)
    let bq = q.toBoundQuery()
    check("NOT EXISTS (SELECT" in bq.sql)

  test "subquery placeholders are renumbered":
    let sq = fromSchema(SubOrder).select("user_id")
      .where("total", Gt, "75")
      .where("total", Lt, "150")
      .subquery()
    let q = fromSchema(SubUser)
      .where("name", Eq, "Alice")
      .whereIn("id", sq)
    let bq = q.toBoundQuery()
    # Main query has $1 for "Alice", subquery has $2 and $3
    check("\"name\" = $1" in bq.sql)
    check("\"total\" > $2" in bq.sql)
    check("\"total\" < $3" in bq.sql)
    check(bq.args == @["Alice", "75", "150"])

  test "multiple subqueries in same query":
    let sq1 = fromSchema(SubOrder).where("total", Gt, "75").subquery()
    let sq2 = fromSchema(SubOrder).where("total", Lt, "150").subquery()
    let q = fromSchema(SubUser)
      .whereIn("id", sq1)
      .whereIn("id", sq2)
    let bq = q.toBoundQuery()
    check(bq.sql.count("IN (") == 2)

  test "subquery with select fields":
    let sq = fromSchema(SubOrder).select("user_id")
      .select("user_id")
      .where("total", Gt, "75")
      .subquery()
    let q = fromSchema(SubUser).whereIn("id", sq)
    let bq = q.toBoundQuery()
    check("SELECT \"user_id\"" in bq.sql)
    check("\"id\" IN (" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "Alice")

  test "correlated subquery with exists":
    # Users with at least one order > 100
    let sq = fromSchema(SubOrder).select("user_id")
      .select("user_id")
      .where("total", Gt, "100")
      .subquery()
    let q = fromSchema(SubUser).whereIn("id", sq)
    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "Alice")
