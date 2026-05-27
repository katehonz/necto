## Тестове за soft deletes

import std/[unittest, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema SoftUser:
  table "test_soft_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  soft_deletes

necto_schema HardUser:
  table "test_hard_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}

suite "Soft deletes":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_soft_users")
    testrepoInstance.exec("""
      CREATE TABLE test_soft_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        deleted_at TIMESTAMP WITH TIME ZONE
      )
    """)
    testrepoInstance.exec("DROP TABLE IF EXISTS test_hard_users")
    testrepoInstance.exec("""
      CREATE TABLE test_hard_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_soft_users")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_hard_users")

  test "schema metadata has softDeletes flag":
    let meta = schemaMeta(SoftUser)
    check(meta.softDeletes == true)
    let meta2 = schemaMeta(HardUser)
    check(meta2.softDeletes == false)

  test "soft delete sets deleted_at instead of removing row":
    var cs = newChangeset(newSoftUser(), {"name": "Ivan"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)
    check(user.deleted_at.isNone)

    var delCs = newChangeset(newSoftUser(), {"id": $user.id, "name": "Ivan"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.delete(delCs)

    let found = testrepoInstance.one(
      fromSchema(SoftUser).where("id", Eq, $user.id)
    )
    check(found.isNone)  # Not visible by default

    let allWithDeleted = testrepoInstance.all(
      fromSchema(SoftUser).includeDeleted().where("id", Eq, $user.id)
    )
    check(allWithDeleted.len == 1)
    check(allWithDeleted[0].deleted_at.isSome)

  test "hard delete permanently removes row":
    var cs = newChangeset(newSoftUser(), {"name": "Maria"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)

    var delCs = newChangeset(newSoftUser(), {"id": $user.id, "name": "Maria"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.hardDelete(delCs)

    let allWithDeleted = testrepoInstance.all(
      fromSchema(SoftUser).includeDeleted().where("id", Eq, $user.id)
    )
    check(allWithDeleted.len == 0)

  test "non-soft-delete schema does hard delete by default":
    var cs = newChangeset(newHardUser(), {"name": "Peter"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)

    var delCs = newChangeset(newHardUser(), {"id": $user.id, "name": "Peter"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.delete(delCs)

    let found = testrepoInstance.one(
      fromSchema(HardUser).where("id", Eq, $user.id)
    )
    check(found.isNone)

  test "onlyDeleted returns only soft-deleted rows":
    var cs1 = newChangeset(newSoftUser(), {"name": "Active"}.toTable)
    cs1 = cs1.castFields(@["name"])
    let u1 = testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newSoftUser(), {"name": "Deleted"}.toTable)
    cs2 = cs2.castFields(@["name"])
    let u2 = testrepoInstance.insert(cs2)

    var delCs = newChangeset(newSoftUser(), {"id": $u2.id, "name": "Deleted"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.delete(delCs)

    let active = testrepoInstance.all(fromSchema(SoftUser))
    check(active.len == 1)
    check(active[0].name == "Active")

    let deleted = testrepoInstance.all(fromSchema(SoftUser).onlyDeleted())
    check(deleted.len == 1)
    check(deleted[0].name == "Deleted")

    let all = testrepoInstance.all(fromSchema(SoftUser).includeDeleted())
    check(all.len == 2)

  test "soft delete is idempotent (does not double-delete)":
    var cs = newChangeset(newSoftUser(), {"name": "Once"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)

    var delCs = newChangeset(newSoftUser(), {"id": $user.id, "name": "Once"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.delete(delCs)
    discard testrepoInstance.delete(delCs)  # Second delete should be no-op

    let all = testrepoInstance.all(fromSchema(SoftUser).includeDeleted())
    check(all.len == 1)

  test "bang versions work":
    var cs = newChangeset(newSoftUser(), {"name": "Bang"}.toTable)
    cs = cs.castFields(@["name"])
    let user = testrepoInstance.insert(cs)

    var delCs = newChangeset(newSoftUser(), {"id": $user.id, "name": "Bang"}.toTable)
    delCs = delCs.castFields(@["id", "name"])
    discard testrepoInstance.`delete!`(delCs)

    let found = testrepoInstance.one(
      fromSchema(SoftUser).where("id", Eq, $user.id)
    )
    check(found.isNone)

    var hdCs = newChangeset(newSoftUser(), {"id": $user.id, "name": "Bang"}.toTable)
    hdCs = hdCs.castFields(@["id", "name"])
    discard testrepoInstance.`hardDelete!`(hdCs)

    let all = testrepoInstance.all(fromSchema(SoftUser).includeDeleted().where("id", Eq, $user.id))
    check(all.len == 0)
