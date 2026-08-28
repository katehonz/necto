## Query DX tests: typed where, paginate, FOR UPDATE, whereIn values, pluck, exists

import std/[unittest, os, strutils, tables, options]
import ../src/necto
import support/test_repo

necto_schema DxUser:
  table "test_dx_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field age: int
  field active: bool

suite "Query DX":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_dx_users")
    testrepoInstance.exec("""
      CREATE TABLE test_dx_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER NOT NULL DEFAULT 0,
        active BOOLEAN NOT NULL DEFAULT true
      )
    """)
    discard testrepoInstance.insert_all(DxUser, @[
      {"name": "Alice", "age": "25", "active": "true"}.toTable,
      {"name": "Bob", "age": "30", "active": "true"}.toTable,
      {"name": "Carol", "age": "17", "active": "false"}.toTable,
      {"name": "Dave", "age": "40", "active": "true"}.toTable,
      {"name": "Eve", "age": "22", "active": "true"}.toTable,
    ])

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_dx_users")

  test "typed where with int":
    let bq = fromSchema(DxUser).where("age", Gte, 18).toBoundQuery()
    check(bq.sql.contains("\"age\""))
    check(bq.args.contains("18"))
    let rows = testrepoInstance.all(fromSchema(DxUser).where("age", Gte, 18))
    check(rows.len == 4)

  test "typed where with bool":
    let rows = testrepoInstance.all(fromSchema(DxUser).where("active", Eq, false))
    check(rows.len == 1)
    check(rows[0].name == "Carol")

  test "paginate is 1-based":
    let page1 = fromSchema(DxUser).orderBy("name", Asc).paginate(1, 2)
    let bq1 = page1.toBoundQuery()
    check(bq1.sql.contains("LIMIT"))
    check(bq1.sql.contains("OFFSET"))
    # page 1 → offset 0, page 2 → offset 2
    check(bq1.args[^2] == "2")  # limit
    check(bq1.args[^1] == "0")  # offset

    let page2 = fromSchema(DxUser).orderBy("name", Asc).paginate(2, 2)
    let bq2 = page2.toBoundQuery()
    check(bq2.args[^1] == "2")

    let rows = testrepoInstance.all(fromSchema(DxUser).orderBy("name", Asc).paginate(1, 2))
    check(rows.len == 2)
    check(rows[0].name == "Alice")
    check(rows[1].name == "Bob")

  test "forUpdate adds lock clause":
    let bq = fromSchema(DxUser).where("id", Eq, 1).forUpdate().toBoundQuery()
    check(bq.sql.contains("FOR UPDATE"))
    check(not bq.sql.contains("NOWAIT"))
    check(not bq.sql.contains("SKIP LOCKED"))

  test "forUpdate skipLocked":
    let bq = fromSchema(DxUser).forUpdate(skipLocked = true).toBoundQuery()
    check(bq.sql.contains("FOR UPDATE"))
    check(bq.sql.contains("SKIP LOCKED"))

  test "forShare noWait":
    let bq = fromSchema(DxUser).forShare(noWait = true).toBoundQuery()
    check(bq.sql.contains("FOR SHARE"))
    check(bq.sql.contains("NOWAIT"))

  test "whereIn with values":
    let q = fromSchema(DxUser).whereIn("name", ["Alice", "Bob"])
    let bq = q.toBoundQuery()
    check(bq.sql.contains("IN ("))
    check(bq.args.contains("Alice"))
    check(bq.args.contains("Bob"))
    let rows = testrepoInstance.all(q)
    check(rows.len == 2)

  test "whereIn empty is always false":
    let rows = testrepoInstance.all(fromSchema(DxUser).whereIn("name", []))
    check(rows.len == 0)

  test "whereNotIn with values":
    let rows = testrepoInstance.all(fromSchema(DxUser).whereNotIn("name", ["Alice", "Bob", "Carol"]))
    check(rows.len == 2)

  test "pluck returns single column":
    let names = testrepoInstance.pluck(fromSchema(DxUser).orderBy("name", Asc), "name")
    check(names == @["Alice", "Bob", "Carol", "Dave", "Eve"])

  test "exists returns true/false":
    check(testrepoInstance.exists(fromSchema(DxUser).where("name", Eq, "Alice")) == true)
    check(testrepoInstance.exists(fromSchema(DxUser).where("name", Eq, "Nobody")) == false)

  test "first is alias of one":
    let u = testrepoInstance.first(fromSchema(DxUser).where("name", Eq, "Bob"))
    check(u.isSome)
    check(u.get.name == "Bob")

  test "COUNT(*) is not identifier-quoted":
    let cq = compileQuery(fromSchema(DxUser).count())
    check("COUNT(*)" in cq.sql)
    check("COUNT(\"*\")" notin cq.sql)

  test "GROUP BY comes before ORDER BY":
    let bq = fromSchema(DxUser).groupBy("active").orderBy("age", Desc).toBoundQuery()
    let groupIdx = bq.sql.find("GROUP BY")
    let orderIdx = bq.sql.find("ORDER BY")
    check(groupIdx >= 0)
    check(orderIdx >= 0)
    check(groupIdx < orderIdx)

  test "count ignores LIMIT and OFFSET":
    let result = testrepoInstance.count(fromSchema(DxUser).limit(2).offset(1))
    check(result.hasGroups == false)
    check(result.total == 5)

  test "update_all with orderBy does not keep ORDER BY":
    let updated = testrepoInstance.update_all(
      fromSchema(DxUser).where("name", Eq, "Eve").orderBy("name", Asc).limit(1),
      {"age": "99"}.toTable
    )
    check(updated == 1)
    let eve = testrepoInstance.one(fromSchema(DxUser).where("name", Eq, "Eve"))
    check(eve.isSome)
    check(eve.get.age == 99)

  test "identifier quoting follows SQL dialect":
    setQueryDialect(pdPostgres)
    check(quoteIdentifier("age") == "\"age\"")
    setQueryDialect(pdSqlite)
    check(quoteIdentifier("age") == "`age`")
    setQueryDialect(pdMariaDb)
    check(quoteIdentifier("user") == "`user`")
    check(quoteIdentifier("a`b") == "`a``b`")
    setQueryDialect(pdPostgres)
    let bq = fromSchema(DxUser).where("age", Gte, 18).toBoundQuery()
    check(bq.sql.contains("\"age\""))

  test "typed int bind encodes as decimal text":
    let bq = fromSchema(DxUser).where("age", Gte, 18).toBoundQuery()
    check(bq.args.contains("18"))
    check(bq.sql.contains("$1"))

  test "typed bool bind encodes for postgres":
    setQueryDialect(pdPostgres)
    let bq = fromSchema(DxUser).where("active", Eq, false).toBoundQuery()
    check(bq.args.contains("false"))
    setQueryDialect(pdSqlite)
    let bqLite = fromSchema(DxUser).where("active", Eq, false).toBoundQuery()
    check(bqLite.args.contains("0"))
    setQueryDialect(pdPostgres)

  test "NULL bind becomes IS NULL":
    let bq = fromSchema(DxUser).where("name", Eq, dbNullValue()).toBoundQuery()
    check(bq.sql.contains("IS NULL"))
    check(bq.sql.find("$1") < 0)

  test "literal field names are compile-time checked":
    # Would fail to compile if "age" were not a DxUser field.
    let rows = testrepoInstance.all(fromSchema(DxUser).where("age", Gte, 18).orderBy("name"))
    check(rows.len == 4)
