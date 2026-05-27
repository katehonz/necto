## Тестове за window functions

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema WfEmployee:
  table "test_wf_employees"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field department: string {.not_null.}
  field salary: int64

suite "Window functions":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_wf_employees")
    testrepoInstance.exec("""
      CREATE TABLE test_wf_employees (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        department TEXT NOT NULL,
        salary BIGINT
      )
    """)
    # Insert test data
    let data = [
      ("Alice", "Engineering", 100000),
      ("Bob", "Engineering", 90000),
      ("Charlie", "Engineering", 110000),
      ("Diana", "Sales", 80000),
      ("Eve", "Sales", 85000),
      ("Frank", "Sales", 75000),
    ]
    for (name, dept, salary) in data:
      testrepoInstance.exec(
        "INSERT INTO test_wf_employees (name, department, salary) VALUES ($1, $2, $3)",
        @[name, dept, $salary]
      )

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_wf_employees")

  test "rowNumber generates correct SQL":
    let q = fromSchema(WfEmployee)
      .select("id", "name", "salary")
      .rowNumber(partitionBy = ["department"], orderByField = "salary", orderDir = Desc, alias = "rn")
    let bq = q.toBoundQuery()
    check("ROW_NUMBER() OVER (PARTITION BY \"department\" ORDER BY \"salary\" DESC) AS \"rn\"" in bq.sql)
    check("FROM \"test_wf_employees\"" in bq.sql)

  test "rowNumber returns correct results":
    let results = testrepoInstance.all(
      fromSchema(WfEmployee)
        .select("id", "name", "salary")
        .rowNumber(partitionBy = ["department"], orderByField = "salary", orderDir = Desc, alias = "rn")
        .orderBy("department", Asc)
        .orderBy("rn", Asc)
    )
    check(results.len == 6)
    # Engineering: Charlie(110k) = 1, Alice(100k) = 2, Bob(90k) = 3
    # Sales: Eve(85k) = 1, Diana(80k) = 2, Frank(75k) = 3

  test "rank generates correct SQL":
    let q = fromSchema(WfEmployee)
      .rank(partitionBy = ["department"], orderByField = "salary", alias = "dept_rank")
    let bq = q.toBoundQuery()
    check("RANK() OVER (PARTITION BY \"department\" ORDER BY \"salary\" ASC) AS \"dept_rank\"" in bq.sql)

  test "denseRank generates correct SQL":
    let q = fromSchema(WfEmployee)
      .denseRank(partitionBy = ["department"], orderByField = "salary", alias = "dr")
    let bq = q.toBoundQuery()
    check("DENSE_RANK() OVER (PARTITION BY \"department\" ORDER BY \"salary\" ASC) AS \"dr\"" in bq.sql)

  test "lag generates correct SQL":
    let q = fromSchema(WfEmployee)
      .select("name", "salary")
      .lag("salary", 1, partitionBy = ["department"], orderByField = "salary", alias = "prev_salary")
    let bq = q.toBoundQuery()
    check("LAG(\"salary\", 1) OVER (PARTITION BY \"department\" ORDER BY \"salary\" ASC) AS \"prev_salary\"" in bq.sql)

  test "lead generates correct SQL":
    let q = fromSchema(WfEmployee)
      .select("name", "salary")
      .lead("salary", 1, partitionBy = ["department"], orderByField = "salary", alias = "next_salary")
    let bq = q.toBoundQuery()
    check("LEAD(\"salary\", 1) OVER (PARTITION BY \"department\" ORDER BY \"salary\" ASC) AS \"next_salary\"" in bq.sql)

  test "window function without select fields uses window functions as select":
    let q = fromSchema(WfEmployee)
      .rowNumber(alias = "rn")
    let bq = q.toBoundQuery()
    check("SELECT ROW_NUMBER() OVER () AS \"rn\"" in bq.sql)

  test "multiple window functions":
    let q = fromSchema(WfEmployee)
      .select("name")
      .rowNumber(partitionBy = ["department"], orderByField = "salary", alias = "rn")
      .rank(partitionBy = ["department"], orderByField = "salary", alias = "rk")
    let bq = q.toBoundQuery()
    check("name" in bq.sql)
    check("ROW_NUMBER()" in bq.sql)
    check("RANK()" in bq.sql)

  test "window function with ORDER BY only":
    let q = fromSchema(WfEmployee)
      .select("name", "salary")
      .rowNumber(orderByField = "salary", orderDir = Desc, alias = "rn")
    let bq = q.toBoundQuery()
    check("ROW_NUMBER() OVER (ORDER BY \"salary\" DESC) AS \"rn\"" in bq.sql)
