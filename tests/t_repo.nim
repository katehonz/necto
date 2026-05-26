## Тестове за Repo и PostgreSQL връзка

import std/[unittest, os, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

suite "Repo connection":
  test "TestRepo is defined":
    check(testrepoInstance != nil)
    check(testrepoInstance.adapter != nil)

  test "Adapter configuration is correct":
    let pg = PostgresAdapter(testrepoInstance.adapter)
    check(pg.host == "localhost")
    check(pg.user == "postgres")
    check(pg.database == "necto_test")
    check(pg.poolSize == 5)

  test "Can execute raw SQL in transaction":
    testrepoInstance.transaction do ():
      testrepoInstance.adapter.exec(
        testrepoInstance.adapter.connect(),
        "SELECT 1",
        @[]
      )
