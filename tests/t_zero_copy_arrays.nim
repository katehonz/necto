## Тестове за zero-allocation array loading

import std/[unittest, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema ArrayEntity:
  table "test_array_entities"
  field id: int64 {.primary_key, auto_increment.}
  field int_arr: seq[int]
  field int64_arr: seq[int64]
  field float_arr: seq[float]
  field bool_arr: seq[bool]
  field str_arr: seq[string]

suite "Zero-copy array loading":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_array_entities")
    testrepoInstance.exec("""
      CREATE TABLE test_array_entities (
        id BIGSERIAL PRIMARY KEY,
        int_arr INT[],
        int64_arr BIGINT[],
        float_arr DOUBLE PRECISION[],
        bool_arr BOOLEAN[],
        str_arr TEXT[]
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_array_entities")

  test "load seq[int] with zero-allocation fast path":
    var cs = newChangeset(newArrayEntity(), {
      "int_arr": "{1,2,3,42,-5}"
    }.toTable)
    cs = cs.castFields(@["int_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.int_arr == @[1, 2, 3, 42, -5])

  test "load seq[int64] with zero-allocation fast path":
    var cs = newChangeset(newArrayEntity(), {
      "int64_arr": "{10000000000,20000000000}"
    }.toTable)
    cs = cs.castFields(@["int64_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.int64_arr == @[10000000000'i64, 20000000000'i64])

  test "load seq[float] with fast path":
    var cs = newChangeset(newArrayEntity(), {
      "float_arr": "{3.14,2.71,-1.0}"
    }.toTable)
    cs = cs.castFields(@["float_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.float_arr.len == 3)
    check(abs(e.float_arr[0] - 3.14) < 0.001)
    check(abs(e.float_arr[1] - 2.71) < 0.001)
    check(abs(e.float_arr[2] - (-1.0)) < 0.001)

  test "load seq[bool] with zero-allocation fast path":
    var cs = newChangeset(newArrayEntity(), {
      "bool_arr": "{t,f,t,t}"
    }.toTable)
    cs = cs.castFields(@["bool_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.bool_arr == @[true, false, true, true])

  test "load seq[string] with generic fallback":
    var cs = newChangeset(newArrayEntity(), {
      "str_arr": "{hello,world,foo bar}"
    }.toTable)
    cs = cs.castFields(@["str_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.str_arr == @["hello", "world", "foo bar"])

  test "empty array loads as empty seq":
    var cs = newChangeset(newArrayEntity(), {
      "int_arr": "{}"
    }.toTable)
    cs = cs.castFields(@["int_arr"])
    let e = testrepoInstance.insert(cs)
    check(e.int_arr.len == 0)

  test "NULL array loads as empty seq":
    let id = testrepoInstance.scalar("INSERT INTO test_array_entities DEFAULT VALUES RETURNING id")
    let e = testrepoInstance.one(
      fromSchema(ArrayEntity).where("id", Eq, id)
    ).get
    check(e.int_arr.len == 0)

  test "roundtrip all array types together":
    var cs = newChangeset(newArrayEntity(), {
      "int_arr": "{10,20,30}",
      "int64_arr": "{9000000000}",
      "float_arr": "{1.5,2.5}",
      "bool_arr": "{t,f}",
      "str_arr": "{a,b,c}"
    }.toTable)
    cs = cs.castFields(@["int_arr", "int64_arr", "float_arr", "bool_arr", "str_arr"])
    let e1 = testrepoInstance.insert(cs)

    let e2 = testrepoInstance.one(
      fromSchema(ArrayEntity).where("id", Eq, $e1.id)
    ).get

    check(e2.int_arr == @[10, 20, 30])
    check(e2.int64_arr == @[9000000000'i64])
    check(e2.float_arr.len == 2)
    check(e2.bool_arr == @[true, false])
    check(e2.str_arr == @["a", "b", "c"])
