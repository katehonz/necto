## Тестове за `change` direction в миграциите

import std/[unittest, tables, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# Дефинираме миграциите на top level (извън suite), защото типовете трябва
# да са глобално видими.

necto_migration TestChangeMigration, "20260527000000":
  change:
    createTable repo, "test_change_items", cols(
      pk("id"),
      col("name", "text", nullable = false),
      col("value", "integer")
    )
    addColumn repo, "test_change_items", "description", "text"
    createIndex repo, "test_change_items", @["name"]

necto_migration TestRenameMigration, "20260527000001":
  change:
    renameTable repo, "test_rename_src", "test_rename_dst"

suite "Migration change direction":
  test "change block generates reversible migration":
    # Cleanup от предишни test runs
    testrepoInstance.exec("DROP TABLE IF EXISTS test_change_items CASCADE")

    let mig = newTestChangeMigration()
    check(mig.version == "20260527000000")
    check(mig.name == "TestChangeMigration")

    # up трябва да създаде таблицата
    mig.up(testrepoInstance)

    let count1 = testrepoInstance.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'test_change_items'")
    check(count1 == "1")

    # down трябва да drop-не таблицата
    mig.down(testrepoInstance)

    let count2 = testrepoInstance.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'test_change_items'")
    check(count2 == "0")

    testrepoInstance.exec("DROP TABLE IF EXISTS test_change_items CASCADE")

  test "renameTable is reversible in change":
    testrepoInstance.exec("CREATE TABLE test_rename_src (id BIGSERIAL PRIMARY KEY)")

    let mig = newTestRenameMigration()
    mig.up(testrepoInstance)

    let countUp = testrepoInstance.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'test_rename_dst'")
    check(countUp == "1")

    mig.down(testrepoInstance)

    let countDown = testrepoInstance.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'test_rename_src'")
    check(countDown == "1")

    testrepoInstance.exec("DROP TABLE IF EXISTS test_rename_src")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_rename_dst")
