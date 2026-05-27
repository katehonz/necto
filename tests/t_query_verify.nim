## Test for Query Verification
##
## Tests verifyQueryAgainstDb against live PostgreSQL.

import std/[unittest, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Test schema ---
necto_schema QvUser:
  table "qv_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  field age: int
  timestamps

suite "Query Verification":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS qv_users CASCADE")
    testrepoInstance.exec("""
      CREATE TABLE qv_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        age INTEGER,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("INSERT INTO qv_users (name, email, age) VALUES ('Test', 't@t.com', 25)")

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS qv_users CASCADE")

  test "verifyQueryAgainstDb passes for valid query":
    let q = fromSchema(QvUser).where("name", Eq, "Test")
    let bq = q.toBoundQuery()
    let cols = q.extractColumns()

    let r = verifyQueryAgainstDb(
      "localhost", 5432, "postgres", "pas+123", "necto_test",
      "qv_users", cols, bq.sql
    )
    check(r.errors.len == 0)

  test "verifyQueryAgainstDb detects non-existent table":
    let q = fromSchema(QvUser).where("name", Eq, "Test")
    let bq = q.toBoundQuery()
    let cols = q.extractColumns()

    let r = verifyQueryAgainstDb(
      "localhost", 5432, "postgres", "pas+123", "necto_test",
      "nonexistent_table_xyz", cols, bq.sql
    )
    check(r.errors.len >= 1)
    var hasTableErr = false
    for e in r.errors:
      if e.find("does not exist") >= 0: hasTableErr = true
    check(hasTableErr)

  test "verifyQueryAgainstDb detects non-existent column":
    let q = fromSchema(QvUser)
    var cols = q.extractColumns()
    cols.add("nonexistent_column")
    let bq = q.toBoundQuery()

    let r = verifyQueryAgainstDb(
      "localhost", 5432, "postgres", "pas+123", "necto_test",
      "qv_users", cols, bq.sql
    )
    check(r.errors.len >= 1)
    var hasBadCol = false
    for e in r.errors:
      if e.find("nonexistent_column") >= 0: hasBadCol = true
    check(hasBadCol)

  test "verifyQueryAgainstDb EXPLAIN validates SQL syntax":
    # Valid SQL passes
    let q = fromSchema(QvUser).where("age", Gt, "18").orderBy("name", Asc)
    let bq = q.toBoundQuery()
    let cols = q.extractColumns()

    let r = verifyQueryAgainstDb(
      "localhost", 5432, "postgres", "pas+123", "necto_test",
      "qv_users", cols, bq.sql
    )
    check(r.errors.len == 0)

  test "extractColumns returns correct columns from Query":
    let q = fromSchema(QvUser)
      .select("id", "name")
      .where("age", Gt, "18")
      .orderBy("name", Asc)

    let cols = q.extractColumns()

    # select: id, name; where: age; orderBy: name
    check("id" in cols)
    check("name" in cols)
    check("age" in cols)
    # name appears twice (select + orderBy) — should still be present
    check(cols.len >= 3)

  test "formatQueryResult formats errors correctly":
    var r = QueryVerifyResult(tableName: "test_table", boundSql: "SELECT 1")
    r.errors.add("Column 'bad' not found")
    r.warnings.add("Index not used")

    let output = formatQueryResult(r)
    check(output.find("test_table") >= 0)
    check(output.find("SELECT 1") >= 0)
    check(output.find("bad") >= 0)
    check(output.find("Index not used") >= 0)