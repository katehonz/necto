## Интеграционен тест: Schema + Query + Changeset + CRUD с реална PostgreSQL

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Schema за интеграционния тест ---

necto_schema User:
  table "test_users_int"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  field age: int
  timestamps

suite "Integration: Schema + Query + Changeset + CRUD":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_users_int\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_users_int" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        age INTEGER,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_users_int\"")

  test "Insert via changeset and load via Query.all":
    let params = {"name": "Ivan", "email": "ivan@test.com", "age": "30"}.toTable
    var cs = newChangeset(newUser(), params)
    cs = cs.castFields(@["name", "email", "age"])
    cs = cs.validateRequired(@["name"])
    check(cs.isValid)

    let user = testrepoInstance.insert(cs)
    check(user.name == "Ivan")
    check(user.email == "ivan@test.com")
    check(user.age == 30)
    check(user.id > 0)

    let users = testrepoInstance.all(fromSchema(User))
    check(users.len == 1)
    check(users[0].name == "Ivan")

  test "Query with WHERE and bound parameters":
    # Seed
    for i, name in @["Alice", "Bob", "Charlie"]:
      let params = {"name": name, "email": name.toLowerAscii() & "@test.com", "age": $(20 + i * 5)}.toTable
      var cs = newChangeset(newUser(), params)
      cs = cs.castFields(@["name", "email", "age"])
      discard testrepoInstance.insert(cs)

    let adults = testrepoInstance.all(
      fromSchema(User).where("age", Gte, "25")
    )
    check(adults.len == 2)  # Bob(25), Charlie(30)

    let ordered = testrepoInstance.all(
      fromSchema(User).orderBy("age", Desc)
    )
    check(ordered.len == 3)
    check(ordered[0].name == "Charlie")
    check(ordered[1].name == "Bob")
    check(ordered[2].name == "Alice")

  test "Query.one returns single result or none":
    let params = {"name": "Solo", "email": "solo@test.com", "age": "42"}.toTable
    var cs = newChangeset(newUser(), params)
    cs = cs.castFields(@["name", "email", "age"])
    discard testrepoInstance.insert(cs)

    let found = testrepoInstance.one(
      fromSchema(User).where("name", Eq, "Solo")
    )
    check(found.isSome)
    check(found.get().email == "solo@test.com")

    let notFound = testrepoInstance.one(
      fromSchema(User).where("name", Eq, "Nobody")
    )
    check(notFound.isNone)

  test "Query.count returns row count":
    for name in @["A", "B", "C"]:
      var cs = newChangeset(newUser(), {"name": name, "age": "10"}.toTable)
      cs = cs.castFields(@["name", "age"])
      discard testrepoInstance.insert(cs)

    let total = testrepoInstance.count(fromSchema(User))
    check(total == 3)

    let filtered = testrepoInstance.count(
      fromSchema(User).where("name", Eq, "A")
    )
    check(filtered == 1)

  test "Update via changeset":
    var cs = newChangeset(newUser(), {"name": "Old", "email": "old@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])
    let user = testrepoInstance.insert(cs)
    let originalId = user.id

    var cs2 = newChangeset(user, {"name": "New"}.toTable)
    cs2 = cs2.castFields(@["name"])
    cs2.changes["id"] = $originalId
    let updated = testrepoInstance.update(cs2)
    check(updated.name == "New")
    check(updated.id == originalId)

    let fetched = testrepoInstance.one(
      fromSchema(User).where("id", Eq, $originalId)
    )
    check(fetched.isSome)
    check(fetched.get().name == "New")

  test "Delete via changeset":
    var cs = newChangeset(newUser(), {"name": "ToDelete"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)
    let uid = user.id

    var csDel = newChangeset(user, initTable[string, string]())
    csDel.changes["id"] = $uid
    discard testrepoInstance.delete(csDel)

    let gone = testrepoInstance.one(
      fromSchema(User).where("id", Eq, $uid)
    )
    check(gone.isNone)

  test "Transaction commits all operations":
    testrepoInstance.transaction do ():
      for name in @["T1", "T2"]:
        var cs = newChangeset(newUser(), {"name": name}.toTable)
        cs = cs.castFields(@["name"])
        discard testrepoInstance.insert(cs)

    let users = testrepoInstance.all(fromSchema(User))
    check(users.len == 2)

  test "Transaction rolls back on error":
    try:
      testrepoInstance.transaction do ():
        var cs = newChangeset(newUser(), {"name": "Rollback"}.toTable)
        cs = cs.castFields(@["name"])
        discard testrepoInstance.insert(cs)
        raise newException(ValueError, "boom")
    except ValueError:
      discard

    let users = testrepoInstance.all(fromSchema(User))
    check(users.len == 0)

  test "Changeset validations prevent invalid insert":
    var cs = newChangeset(newUser(), {"email": "no-name@test.com"}.toTable)
    cs = cs.castFields(@["name", "email"])
    cs = cs.validateRequired(@["name"])
    check(cs.isInvalid)

    var raised = false
    try:
      discard testrepoInstance.`insert!`(cs)
    except ValidationError:
      raised = true
    check(raised)
