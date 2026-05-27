## Test for Compiled Query Cache
##
## Tests compileQuery + querySql.

import std/[unittest, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema CqUser:
  table "cq_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field age: int
  field active: bool
  timestamps

suite "Compiled Query Cache":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS cq_users CASCADE")
    testrepoInstance.exec("""
      CREATE TABLE cq_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER,
        active BOOLEAN DEFAULT true,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    for i in 1..10:
      let name = "User_" & $i
      let age = $(20 + i)
      testrepoInstance.exec(
        "INSERT INTO cq_users (name, age, active) VALUES ('" & name & "', " & age & ", true)")

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS cq_users CASCADE")

  test "compileQuery pre-computes SQL for static query":
    let cq = compileQuery(fromSchema(CqUser).orderBy("id", Asc))
    check(cq.sql.len > 0)
    check(cq.sql.find("SELECT") >= 0)
    check(cq.sql.find("cq_users") >= 0)
    check(cq.sql.find("ORDER BY") >= 0)
    check(cq.args.len == 0)

  test "compileQuery produces bindings for parameterized query":
    let cq = compileQuery(fromSchema(CqUser).where("age", Gt, "18").orderBy("name", Asc))
    check(cq.sql.find("$1") >= 0)
    check(cq.args.len >= 1)

  test "querySql resolves placeholders to NULL":
    let sql = querySql(fromSchema(CqUser).where("age", Gt, "18").limit(10))
    check(sql.find("$1") < 0)
    check(sql.find("NULL") >= 0)
    check(sql.find("SELECT") >= 0)
    check(sql.find("cq_users") >= 0)

  test "compileQuery works for select fields":
    let cq = compileQuery(fromSchema(CqUser).select("id", "name").orderBy("id", Asc))
    check(cq.sql.find("id") >= 0)
    check(cq.sql.find("name") >= 0)
    check(cq.sql.find("*") < 0)

  test "compileQuery includes LIMIT and OFFSET":
    let cq = compileQuery(fromSchema(CqUser).limit(5).offset(10))
    check(cq.sql.find("LIMIT") >= 0)
    check(cq.sql.find("OFFSET") >= 0)

  test "compileQuery includes DISTINCT":
    let cq = compileQuery(fromSchema(CqUser).setDistinct())
    check(cq.sql.find("DISTINCT") >= 0)

  test "compileQuery for COUNT aggregate":
    let cq = compileQuery(fromSchema(CqUser).count())
    check(cq.sql.find("COUNT") >= 0)

  test "cached query produces same results as direct query":
    # Seed data
    let allUsers = testrepoInstance.all(fromSchema(CqUser).orderBy("id", Asc))
    check(allUsers.len == 10)

    # Now use cached query with same structure
    let cachedQ = compileQuery(fromSchema(CqUser).orderBy("id", Asc))
    # Verify the cached SQL matches direct toBoundQuery
    let directQ = fromSchema(CqUser).orderBy("id", Asc)
    let directBq = directQ.toBoundQuery()
    check(cachedQ.sql == directBq.sql)
    check(cachedQ.args == directBq.args)

  test "HAVING with Eq operator generates valid SQL":
    let q = fromSchema(CqUser).groupBy("active").having("age", Eq, "25")
    let bq = q.toBoundQuery()
    check(bq.sql.find("GROUP BY") >= 0)
    check(bq.sql.find("HAVING") >= 0)
    check(bq.sql.find("\"age\" = $1") >= 0)

  test "HAVING with Like operator generates valid SQL":
    let q = fromSchema(CqUser).groupBy("active").having("name", Like, "%test%")
    let bq = q.toBoundQuery()
    check(bq.sql.find("\"name\" LIKE $") >= 0)

  test "HAVING with In operator generates valid SQL":
    let q = fromSchema(CqUser).groupBy("active").having("age", In, "25")
    let bq = q.toBoundQuery()
    check(bq.sql.find("\"age\" IN ($") >= 0)

  test "HAVING with IsNull operator generates valid SQL":
    let q = fromSchema(CqUser).groupBy("active").having("name", IsNull, "")
    let bq = q.toBoundQuery()
    check(bq.sql.find("\"name\" IS NULL") >= 0)
    check(bq.sql.find("$1") < 0)  # No placeholder for IS NULL

  test "HAVING with multiple clauses uses conjunction":
    let q = fromSchema(CqUser).groupBy("active")
      .having("age", Gt, "18")
      .having("name", Like, "%A%")
    let bq = q.toBoundQuery()
    check(bq.sql.find("AND") >= 0)

  test "count() with GROUP BY raises QueryError":
    var raised = false
    try:
      discard testrepoInstance.count(
        fromSchema(CqUser).groupBy("active")
      )
    except QueryError:
      raised = true
    check(raised)