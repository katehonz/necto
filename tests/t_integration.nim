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

necto_schema OptUser:
  table "test_opt_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field nickname: Option[string]
  field score: Option[int]

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
    check(total.total == 3)

    let filtered = testrepoInstance.count(
      fromSchema(User).where("name", Eq, "A")
    )
    check(filtered.total == 1)

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

  test "insert_all batch inserts multiple records":
    var css: seq[Changeset[User]] = @[]
    for name in @["Batch1", "Batch2", "Batch3"]:
      var cs = newChangeset(newUser(), {"name": name, "email": name.toLowerAscii() & "@test.com", "age": $(name.len * 5)}.toTable)
      cs = cs.castFields(@["name", "email", "age"])
      css.add(cs)

    let users = testrepoInstance.insert_all(css)
    check(users.len == 3)
    check(users[0].name == "Batch1")
    check(users[1].name == "Batch2")
    check(users[2].name == "Batch3")
    check(users[0].id > 0)
    check(users[1].id > 0)
    check(users[2].id > 0)

    let allUsers = testrepoInstance.all(fromSchema(User).orderBy("id", Asc))
    check(allUsers.len == 3)
    check(allUsers[0].email == "batch1@test.com")
    check(allUsers[1].age == 30)  # "Batch2".len * 5 = 6 * 5 = 30

  test "insert_all with empty seq returns empty":
    let empty: seq[Changeset[User]] = @[]
    let users = testrepoInstance.insert_all(empty)
    check(users.len == 0)

  test "insert_all raw entries batch inserts without changesets":
    let entries = @[
      {"name": "Raw1", "email": "raw1@test.com", "age": "21"}.toTable,
      {"name": "Raw2", "email": "raw2@test.com", "age": "22"}.toTable,
      {"name": "Raw3", "email": "raw3@test.com", "age": "23"}.toTable
    ]
    let users = testrepoInstance.insert_all(User, entries)
    check(users.len == 3)
    check(users[0].name == "Raw1")
    check(users[1].name == "Raw2")
    check(users[2].name == "Raw3")
    check(users[0].email == "raw1@test.com")
    check(users[1].age == 22)
    check(users[2].id > 0)

    let allUsers = testrepoInstance.all(fromSchema(User).orderBy("id", Asc))
    check(allUsers.len == 3)
    check(allUsers[0].name == "Raw1")
    check(allUsers[1].name == "Raw2")

  test "insert_all raw entries with empty seq returns empty":
    let empty: seq[Table[string, string]] = @[]
    let users = testrepoInstance.insert_all(User, empty)
    check(users.len == 0)

  test "update_all updates matching records":
    for name in @["A", "B", "C"]:
      var cs = newChangeset(newUser(), {"name": name, "active": "true"}.toTable)
      cs = cs.castFields(@["name"])
      discard testrepoInstance.insert(cs)

    let updated = testrepoInstance.update_all(
      fromSchema(User).where("name", Eq, "A"),
      {"name": "Alpha"}.toTable
    )
    check(updated == 1)

    let found = testrepoInstance.one(fromSchema(User).where("name", Eq, "Alpha"))
    check(found.isSome)

  test "delete_all deletes matching records":
    for name in @["Del1", "Del2", "Del3"]:
      var cs = newChangeset(newUser(), {"name": name}.toTable)
      cs = cs.castFields(@["name"])
      discard testrepoInstance.insert(cs)

    let deleted = testrepoInstance.delete_all(
      fromSchema(User).where("name", Eq, "Del2")
    )
    check(deleted == 1)

    let remaining = testrepoInstance.all(fromSchema(User).where("name", Eq, "Del2"))
    check(remaining.len == 0)

  test "validateConfirmation catches mismatch":
    var cs = newChangeset(newUser(), {"password": "secret", "password_confirmation": "wrong"}.toTable)
    cs = cs.castFields(@["password"])
    cs = cs.validateConfirmation("password")
    check(cs.isInvalid)
    check(cs.getError("password")[0] == "doesn't match confirmation")

  test "validateConfirmation passes on match":
    var cs = newChangeset(newUser(), {"password": "secret", "password_confirmation": "secret"}.toTable)
    cs = cs.castFields(@["password"])
    cs = cs.validateConfirmation("password")
    check(cs.isValid)

  test "validateExclusion catches reserved values":
    var cs = newChangeset(newUser(), {"name": "admin"}.toTable)
    cs = cs.castFields(@["name"])
    cs = cs.validateExclusion("name", @["admin", "root", "system"])
    check(cs.isInvalid)
    check(cs.getError("name")[0] == "is reserved")

  test "validateExclusion passes on allowed values":
    var cs = newChangeset(newUser(), {"name": "Ivan"}.toTable)
    cs = cs.castFields(@["name"])
    cs = cs.validateExclusion("name", @["admin", "root", "system"])
    check(cs.isValid)

  test "Pipe operator |> works for query chaining":
    for name in @["PipeA", "PipeB", "PipeC"]:
      var cs = newChangeset(newUser(), {"name": name}.toTable)
      cs = cs.castFields(@["name"])
      discard testrepoInstance.insert(cs)

    let found = User |> fromSchema |> where("name", Eq, "PipeB") |> testrepoInstance.one
    check(found.isSome)
    check(found.get().name == "PipeB")

    let all = User |> fromSchema |> testrepoInstance.all
    check(all.len >= 3)

  test "validateRequired on update uses existing data":
    var cs = newChangeset(newUser(), {"name": "KeepName", "email": "keep@test.com", "age": "33"}.toTable)
    cs = cs.castFields(@["name", "email", "age"])
    let user = testrepoInstance.insert(cs)

    var updateCs = newChangeset(user, {"age": "34"}.toTable)
    updateCs = updateCs.castFields(@["age"])
    updateCs = updateCs.validateRequired(@["name", "age"])
    check(updateCs.isValid)
    let updated = testrepoInstance.update(updateCs)
    check(updated.age == 34)
    check(updated.name == "KeepName")

  test "delete uses primary key from loaded data":
    var cs = newChangeset(newUser(), {"name": "ToDelete"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)
    check(user.id > 0)

    var delCs = newChangeset(user)
    discard testrepoInstance.delete(delCs)
    let gone = testrepoInstance.one(fromSchema(User).where("name", Eq, "ToDelete"))
    check(gone.isNone)

  test "insert_all pads missing fields with DEFAULT":
    var cs1 = newChangeset(newUser(), {"name": "Full", "email": "full@test.com", "age": "10"}.toTable)
    cs1 = cs1.castFields(@["name", "email", "age"])
    var cs2 = newChangeset(newUser(), {"name": "Partial", "age": "11"}.toTable)
    cs2 = cs2.castFields(@["name", "age"])
    let users = testrepoInstance.insert_all(@[cs1, cs2])
    check(users.len == 2)
    check(users[0].name == "Full")
    check(users[0].email == "full@test.com")
    check(users[1].name == "Partial")

  test "optional fields bind SQL NULL and load as none":
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_opt_users\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_opt_users" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        nickname TEXT,
        score INTEGER
      )
    """)
    var cs = newChangeset(newOptUser(), {"name": "NoNick", "nickname": "", "score": ""}.toTable)
    cs = cs.castFields(@["name", "nickname", "score"])
    let u = testrepoInstance.insert(cs)
    check(u.name == "NoNick")
    check(u.nickname.isNone)
    check(u.score.isNone)
    let raw = testrepoInstance.queryRaw(
      "SELECT nickname IS NULL, score IS NULL FROM \"test_opt_users\" WHERE id = $1", @[$u.id])
    check(raw.len == 1)
    check(raw[0][0] == "t")
    check(raw[0][1] == "t")

    var cs2 = newChangeset(newOptUser(), {"name": "HasNick", "nickname": "neo", "score": "7"}.toTable)
    cs2 = cs2.castFields(@["name", "nickname", "score"])
    let u2 = testrepoInstance.insert(cs2)
    check(u2.nickname.isSome)
    check(u2.nickname.get == "neo")
    check(u2.score.isSome)
    check(u2.score.get == 7)
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_opt_users\"")
