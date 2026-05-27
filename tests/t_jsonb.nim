## Тест за типизиран JSONB — JsonB[T]
##
## Проверява че JsonB[T] работи със schema, insert, load, query.

import std/[unittest, tables, json]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Типове за JSONB ---

type
  UserSettings* = object
    theme*: string
    notifications*: bool

  Address* = object
    street*: string
    city*: string
    zip*: int

# --- Schema с JsonB поле ---

necto_schema JsonUser:
  table "test_json_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field settings: JsonB[UserSettings]
  field address: JsonB[Address]
  timestamps

suite "Typed JSONB (JsonB[T])":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_json_users\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_json_users" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        settings JSONB,
        address JSONB,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_json_users\"")

  test "Insert and load typed JSONB fields":
    let settingsJson = """{"theme":"dark","notifications":true}"""
    let addressJson = """{"street":"Main St 42","city":"Sofia","zip":1000}"""

    var cs = newChangeset(newJsonUser(), {
      "name": "Ivan",
      "settings": settingsJson,
      "address": addressJson
    }.toTable)
    cs = cs.castFields(@["name", "settings", "address"])
    check(cs.isValid)

    let user = testrepoInstance.insert(cs)
    check(user.name == "Ivan")

    # Проверяваме типизиран достъп чрез .val
    check(user.settings.val.theme == "dark")
    check(user.settings.val.notifications == true)
    check(user.address.val.street == "Main St 42")
    check(user.address.val.city == "Sofia")
    check(user.address.val.zip == 1000)

  test "Query with typed JSONB fields":
    var cs1 = newChangeset(newJsonUser(), {
      "name": "Alice",
      "settings": """{"theme":"light","notifications":false}""",
      "address": """{"street":"Oak Ave 1","city":"Plovdiv","zip":4000}"""
    }.toTable)
    cs1 = cs1.castFields(@["name", "settings", "address"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonUser(), {
      "name": "Bob",
      "settings": """{"theme":"dark","notifications":true}""",
      "address": """{"street":"Pine Rd 7","city":"Varna","zip":9000}"""
    }.toTable)
    cs2 = cs2.castFields(@["name", "settings", "address"])
    discard testrepoInstance.insert(cs2)

    let users = testrepoInstance.all(fromSchema(JsonUser).orderBy("id", Asc))
    check(users.len == 2)
    check(users[0].name == "Alice")
    check(users[0].settings.val.theme == "light")
    check(users[0].settings.val.notifications == false)
    check(users[1].name == "Bob")
    check(users[1].settings.val.theme == "dark")
    check(users[1].settings.val.notifications == true)

  test "Type system roundtrip — JsonB[T]":
    let raw = """{"theme":"solarized","notifications":true}"""
    let loaded = loadValue(raw, JsonB[UserSettings])
    check(loaded.val.theme == "solarized")
    check(loaded.val.notifications == true)

    let dumped = dumpValue(loaded)
    # Проверяваме че dump-натото парсва обратно
    let reparsed = parseJson(dumped)
    check(reparsed["theme"].getStr == "solarized")
    check(reparsed["notifications"].getBool == true)

  test "JsonB with null/empty":
    let empty = loadValue("", JsonB[Address])
    check(empty.val.street == "")
    check(empty.val.city == "")
    check(empty.val.zip == 0)

    let nullVal = loadValue("null", JsonB[Address])
    check(nullVal.val.street == "")
    check(nullVal.val.city == "")
    check(nullVal.val.zip == 0)

  test "JsonB equality":
    let a = loadValue("""{"theme":"dark","notifications":true}""", JsonB[UserSettings])
    let b = loadValue("""{"theme":"dark","notifications":true}""", JsonB[UserSettings])
    check(a == b)
