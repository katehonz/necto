## Тестове за cursor-based streaming

import std/[unittest, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema StreamUser:
  table "test_stream_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field age: int

suite "Streaming":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_stream_users")
    testrepoInstance.exec("""
      CREATE TABLE test_stream_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER
      )
    """)
    # Insert 25 users
    for i in 1..25:
      testrepoInstance.exec(
        "INSERT INTO test_stream_users (name, age) VALUES ($1, $2)",
        @["User" & $i, $i]
      )

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_stream_users")

  test "forStream iterates all rows":
    var names: seq[string] = @[]
    forStream(testrepoInstance, fromSchema(StreamUser).orderBy("id", Asc), user):
      names.add(user.name)
    check(names.len == 25)
    check(names[0] == "User1")
    check(names[24] == "User25")

  test "forStream with where filter":
    var names: seq[string] = @[]
    forStream(testrepoInstance, fromSchema(StreamUser).where("age", Gte, "20").orderBy("id", Asc), user):
      names.add(user.name)
    check(names.len == 6)  # User20..User25
    check(names[0] == "User20")

  test "forStream with small batch size":
    var names: seq[string] = @[]
    var iter = testrepoInstance.stream(fromSchema(StreamUser).orderBy("id", Asc), batchSz = 3)
    try:
      while true:
        let userOpt = iter.next()
        if userOpt.isNone: break
        names.add(userOpt.get.name)
    finally:
      iter.close()
    check(names.len == 25)

  test "manual stream iteration":
    var iter = testrepoInstance.stream(fromSchema(StreamUser).orderBy("id", Asc), batchSz = 5)
    var count = 0
    try:
      while true:
        let opt = iter.next()
        if opt.isNone: break
        inc count
    finally:
      iter.close()
    check(count == 25)

  test "stream with empty result":
    var names: seq[string] = @[]
    forStream(testrepoInstance, fromSchema(StreamUser).where("age", Gt, "100"), user):
      names.add(user.name)
    check(names.len == 0)

  test "stream does not leak connections":
    # Open and close multiple streams
    for i in 1..10:
      var count = 0
      forStream(testrepoInstance, fromSchema(StreamUser), user):
        inc count
      check(count == 25)
