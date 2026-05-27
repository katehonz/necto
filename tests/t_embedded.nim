## Тестове за embedded schemas (embeds_one / embeds_many)

import std/[unittest, tables, options, json]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

type Address = object
  street*: string
  city*: string

type Profile = object
  bio*: string
  age*: int

necto_schema EmbeddedUser:
  table "test_embedded_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  embeds_one profile: Profile
  embeds_many addresses: Address
  timestamps

suite "Embedded schemas":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_embedded_users")
    testrepoInstance.exec("""
      CREATE TABLE test_embedded_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        profile JSONB,
        addresses JSONB,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_embedded_users")

  test "embeds_one stores and loads typed JSONB":
    var cs = newChangeset(newEmbeddedUser(), {
      "name": "Ivan",
      "profile": """{"bio": "Hello", "age": 30}"""
    }.toTable)
    cs = cs.castFields(@["name", "profile"])
    let user = testrepoInstance.insert(cs)

    check(user.name == "Ivan")
    check(user.profile.val.bio == "Hello")
    check(user.profile.val.age == 30)

  test "embeds_many stores and loads array JSONB":
    var cs = newChangeset(newEmbeddedUser(), {
      "name": "Maria",
      "addresses": """[{"street": "Main St", "city": "Sofia"}, {"street": "Second St", "city": "Plovdiv"}]"""
    }.toTable)
    cs = cs.castFields(@["name", "addresses"])
    let user = testrepoInstance.insert(cs)

    check(user.name == "Maria")
    check(user.addresses.val.len == 2)
    check(user.addresses.val[0].street == "Main St")
    check(user.addresses.val[1].city == "Plovdiv")

  test "Query embedded user from database":
    var cs = newChangeset(newEmbeddedUser(), {
      "name": "Test",
      "profile": """{"bio": "Tester", "age": 25}""",
      "addresses": "[]"
    }.toTable)
    cs = cs.castFields(@["name", "profile", "addresses"])
    discard testrepoInstance.insert(cs)

    let found = testrepoInstance.one(
      fromSchema(EmbeddedUser).where("name", Eq, "Test")
    )
    check(found.isSome)
    check(found.get.profile.val.bio == "Tester")
    check(found.get.addresses.val.len == 0)
