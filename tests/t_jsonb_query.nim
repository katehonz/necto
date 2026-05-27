## Тестове за JSONB query operators

import std/[unittest, tables, options, json, strutils]

# Option полета за embedded типове позволяват липсващи JSON ключове при десериализация
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

type Profile = object
  bio*: string
  age*: Option[int]
  verified*: Option[bool]

type Settings = object
  theme*: Option[string]
  notifications*: Option[bool]

necto_schema JsonbUser:
  table "test_jsonb_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  embeds_one profile: Profile
  embeds_one settings: Settings
  timestamps

suite "JSONB query operators":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_jsonb_users")
    testrepoInstance.exec("""
      CREATE TABLE test_jsonb_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        profile JSONB,
        settings JSONB,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_jsonb_users")

  test "whereJsonbContains finds matching rows":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "Ivan",
      "profile": """{"bio": "Hello", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "Maria",
      "profile": """{"bio": "World", "age": 25, "verified": false}""",
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser).whereJsonbContains("profile", """{"verified": true}""")
    )
    check(results.len == 1)
    check(results[0].name == "Ivan")

  test "whereJsonbHasKey finds rows with key":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "A",
      "profile": """{"bio": "x", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "B",
      "profile": """{"bio": "y", "age": 0}"""
    ,
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser).whereJsonbHasKey("profile", "verified")
    )
    check(results.len == 1)
    check(results[0].name == "A")

  test "whereJsonbHasAnyKeys finds rows with any of the keys":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "A",
      "profile": """{"bio": "x", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "B",
      "profile": """{"bio": "z", "nickname": "y", "age": 0, "verified": false}"""
    ,
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser).whereJsonbHasAnyKeys("profile", @["age", "nickname"])
    )
    check(results.len == 2)

  test "whereJsonbHasAllKeys finds rows with all keys":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "A",
      "profile": """{"bio": "x", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "B",
      "profile": """{"bio": "y", "age": 0}"""
    ,
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser).whereJsonbHasAllKeys("profile", @["bio", "verified"])
    )
    check(results.len == 1)
    check(results[0].name == "A")

  test "whereRawField with jsonbPathText filters by nested value":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "DarkUser",
      "settings": """{"theme": "dark", "notifications": true}"""
    }.toTable)
    cs1 = cs1.castFields(@["name", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "LightUser",
      "settings": """{"theme": "light", "notifications": false}"""
    }.toTable)
    cs2 = cs2.castFields(@["name", "settings"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser).whereRawField(
        jsonbPathText("settings", ["theme"]), Eq, "dark"
      )
    )
    check(results.len == 1)
    check(results[0].name == "DarkUser")

  test "combined normal where and jsonb where":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "Ivan",
      "profile": """{"bio": "Hello", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "Ivan",
      "profile": """{"bio": "World", "age": 20, "verified": false}"""
    ,
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs2)

    let results = testrepoInstance.all(
      fromSchema(JsonbUser)
        .where("name", Eq, "Ivan")
        .whereJsonbContains("profile", """{"verified": true}""")
    )
    check(results.len == 1)
    check(results[0].name == "Ivan")

  test "whereJsonbIt macro generates correct SQL":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "MacroUser",
      "settings": """{"theme": "dark", "notifications": true}"""
    }.toTable)
    cs1 = cs1.castFields(@["name", "settings"])
    discard testrepoInstance.insert(cs1)

    let q = fromSchema(JsonbUser).whereJsonbIt(settings.theme == "dark")
    let bq = q.toBoundQuery()
    check("\"settings\" #>> '{theme}'" in bq.sql)
    check("= $1" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "MacroUser")

  test "fragment placeholders are correctly renumbered":
    var cs1 = newChangeset(newJsonbUser(), {
      "name": "X",
      "profile": """{"bio": "x", "age": 30, "verified": true}"""
    ,
      "settings": "{}"
    }.toTable)
    cs1 = cs1.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newJsonbUser(), {
      "name": "Y",
      "profile": """{"bio": "y", "age": 25, "verified": false}"""
    ,
      "settings": "{}"
    }.toTable)
    cs2 = cs2.castFields(@["name", "profile", "settings"])
    discard testrepoInstance.insert(cs2)

    let q = fromSchema(JsonbUser)
      .where("name", Eq, "X")
      .whereJsonbContains("profile", """{"age": 30}""")
    let bq = q.toBoundQuery()
    # Проверяваме че placeholders са $1 и $2, не $1 и $1
    check("\"name\" = $1" in bq.sql)
    check("\"profile\" @> $2" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].name == "X")
