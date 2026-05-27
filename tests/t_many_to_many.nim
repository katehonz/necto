## Тестове за many_to_many асоциации

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# Forward declare Role за User
necto_schema Role:
  table "test_roles_m2m"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  timestamps

necto_schema User:
  table "test_users_m2m"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  timestamps
  many_to_many roles: Role through "test_user_roles"

suite "Many-to-many associations":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_user_roles")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_roles_m2m")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_users_m2m")
    testrepoInstance.exec("""
      CREATE TABLE test_users_m2m (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_roles_m2m (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_user_roles (
        user_id BIGINT REFERENCES test_users_m2m(id) ON DELETE CASCADE,
        role_id BIGINT REFERENCES test_roles_m2m(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, role_id)
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_user_roles")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_roles_m2m")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_users_m2m")

  test "Schema metadata for many_to_many is correct":
    let userMeta = schemaMeta(User)
    var found = false
    for a in userMeta.associations:
      if a.name == "roles" and a.kind == akManyToMany:
        check(a.targetSchema == "Role")
        check(a.joinTable == "test_user_roles")
        found = true
        break
    check(found)

  test "many_to_many preload loads associated records":
    # Create users
    var u1cs = newChangeset(newUser(), {"name": "Alice"}.toTable)
    u1cs = u1cs.castFields(@["name"])
    let alice = testrepoInstance.insert(u1cs)

    var u2cs = newChangeset(newUser(), {"name": "Bob"}.toTable)
    u2cs = u2cs.castFields(@["name"])
    let bob = testrepoInstance.insert(u2cs)

    # Create roles
    var r1cs = newChangeset(newRole(), {"name": "Admin"}.toTable)
    r1cs = r1cs.castFields(@["name"])
    let admin = testrepoInstance.insert(r1cs)

    var r2cs = newChangeset(newRole(), {"name": "Editor"}.toTable)
    r2cs = r2cs.castFields(@["name"])
    let editor = testrepoInstance.insert(r2cs)

    var r3cs = newChangeset(newRole(), {"name": "Viewer"}.toTable)
    r3cs = r3cs.castFields(@["name"])
    let viewer = testrepoInstance.insert(r3cs)

    # Link Alice → Admin, Editor
    testrepoInstance.exec("INSERT INTO test_user_roles (user_id, role_id) VALUES ($1, $2), ($3, $4)",
      @[$alice.id, $admin.id, $alice.id, $editor.id])
    # Link Bob → Editor, Viewer
    testrepoInstance.exec("INSERT INTO test_user_roles (user_id, role_id) VALUES ($1, $2), ($3, $4)",
      @[$bob.id, $editor.id, $bob.id, $viewer.id])

    # Preload roles
    let users = testrepoInstance.all(
      fromSchema(User).orderBy("id", Asc).preload("roles")
    )
    check(users.len == 2)
    check(users[0].name == "Alice")
    check(users[0].roles.len == 2)
    check(users[0].roles[0].name == "Admin" or users[0].roles[0].name == "Editor")

    check(users[1].name == "Bob")
    check(users[1].roles.len == 2)
    check(users[1].roles[0].name == "Editor" or users[1].roles[0].name == "Viewer")

  test "many_to_many preload works with repo.allWithPreload":
    var u1cs = newChangeset(newUser(), {"name": "Charlie"}.toTable)
    u1cs = u1cs.castFields(@["name"])
    let charlie = testrepoInstance.insert(u1cs)

    var r1cs = newChangeset(newRole(), {"name": "Moderator"}.toTable)
    r1cs = r1cs.castFields(@["name"])
    let moderator = testrepoInstance.insert(r1cs)

    testrepoInstance.exec("INSERT INTO test_user_roles (user_id, role_id) VALUES ($1, $2)",
      @[$charlie.id, $moderator.id])

    let users = testrepoInstance.allWithPreload(
      fromSchema(User).where("name", Eq, "Charlie"), "roles"
    )
    check(users.len == 1)
    check(users[0].roles.len == 1)
    check(users[0].roles[0].name == "Moderator")
