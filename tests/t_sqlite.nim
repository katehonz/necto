## SQLite Adapter Integration Test
##
## Тества основни CRUD операции, транзакции и миграции с SQLite (in-memory).

import std/[unittest]
import necto
import necto/adapters/sqlite

# --- Repo ---

necto_repo SqliteTestRepo:
  adapter SqliteAdapter
  database ":memory:"
  pool_size 1

# --- Helpers ---

proc setupTables(repo: Repo) =
  repo.exec("""
    CREATE TABLE IF NOT EXISTS `users` (
      `id` INTEGER PRIMARY KEY AUTOINCREMENT,
      `name` TEXT NOT NULL,
      `email` TEXT NOT NULL,
      `age` INTEGER,
      `active` INTEGER DEFAULT 1,
      `created_at` TEXT DEFAULT (datetime('now')),
      `updated_at` TEXT DEFAULT (datetime('now'))
    )
  """)

  repo.exec("""
    CREATE TABLE IF NOT EXISTS `posts` (
      `id` INTEGER PRIMARY KEY AUTOINCREMENT,
      `title` TEXT NOT NULL,
      `user_id` INTEGER,
      `created_at` TEXT DEFAULT (datetime('now')),
      `updated_at` TEXT DEFAULT (datetime('now'))
    )
  """)

# --- Tests ---

suite "SQLite Adapter Integration":
  let repo = newSqliteTestRepo()
  setupTables(repo)

  setup:
    repo.exec("DELETE FROM `users`")
    repo.exec("DELETE FROM `posts`")

  test "basic insert and query via raw SQL":
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["Ivan", "ivan@test.com", "25"])

    let rows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["Ivan"])
    check rows.len == 1
    check rows[0][1] == "Ivan"
    check rows[0][2] == "ivan@test.com"

  test "insert returning via adapter":
    let conn = repo.adapter.connect()
    let id = repo.adapter.insertReturning(conn, "INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", "id", @["Maria", "maria@test.com", "30"])
    check id > 0
    repo.adapter.disconnect(conn)

    let rows = repo.queryRaw("SELECT * FROM `users` WHERE `id` = ?", @[$id])
    check rows.len == 1
    check rows[0][1] == "Maria"

  test "update via raw SQL":
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["Peter", "peter@test.com", "40"])
    repo.exec("UPDATE `users` SET `age` = ? WHERE `name` = ?", @["41", "Peter"])

    let rows = repo.queryRaw("SELECT `age` FROM `users` WHERE `name` = ?", @["Peter"])
    check rows.len == 1
    check rows[0][0] == "41"

  test "delete via raw SQL":
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["DeleteMe", "del@test.com", "20"])
    repo.exec("DELETE FROM `users` WHERE `name` = ?", @["DeleteMe"])

    let rows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["DeleteMe"])
    check rows.len == 0

  test "transaction commit":
    repo.transaction() do ():
      repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["TxUser", "tx@test.com", "20"])

    let rows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["TxUser"])
    check rows.len == 1

  test "transaction rollback":
    try:
      repo.transaction() do ():
        repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["RollbackUser", "rb@test.com", "20"])
        raise newException(ValueError, "force rollback")
    except ValueError:
      discard

    let rows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["RollbackUser"])
    check rows.len == 0

  test "scalar":
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["ScalarUser", "scalar@test.com", "50"])
    let count = repo.scalar("SELECT COUNT(*) FROM `users` WHERE `age` > ?", @["40"])
    check count == "1"

  test "execAffected":
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["Aff1", "aff1@test.com", "10"])
    repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["Aff2", "aff2@test.com", "20"])
    let affected = repo.adapter.execAffected(repo.getWriteConn(), "UPDATE `users` SET `age` = ? WHERE `name` LIKE ?", @["99", "Aff%"])
    check affected == 2

  test "pool metrics":
    let metrics = repo.poolMetrics()
    check metrics.totalRequests >= 0

  test "savepoint rollback":
    repo.transaction() do ():
      repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["SaveOuter", "outer@test.com", "10"])
      try:
        repo.savepoint("sp1"):
          repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["SaveInner", "inner@test.com", "20"])
          raise newException(ValueError, "Simulated failure")
      except ValueError:
        discard

    let outerRows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["SaveOuter"])
    check outerRows.len == 1
    let innerRows = repo.queryRaw("SELECT * FROM `users` WHERE `name` = ?", @["SaveInner"])
    check innerRows.len == 0

  test "streaming via LIMIT/OFFSET":
    for i in 1..5:
      repo.exec("INSERT INTO `users` (`name`, `email`, `age`) VALUES (?, ?, ?)", @["Stream" & $i, "stream" & $i & "@test.com", $i])

    let conn = repo.getReadConn()
    var allNames: seq[string] = @[]
    var offset = 0
    while true:
      let rows = repo.adapter.query(conn, "SELECT `name` FROM `users` WHERE `name` LIKE ? ORDER BY `id` LIMIT 2 OFFSET " & $offset, @["Stream%"])
      if rows.len == 0: break
      for row in rows:
        allNames.add(row[0])
      offset += 2
    repo.releaseConn(conn)
    check allNames.len == 5

  test "migration helpers create table":
    let testRepo = newSqliteTestRepo()
    testRepo.exec("DROP TABLE IF EXISTS `migrate_test`")
    let cols = @[
      ColumnDef(name: "id", dbType: "bigserial", primaryKey: true, null: false),
      ColumnDef(name: "title", dbType: "text", null: false),
      ColumnDef(name: "count", dbType: "integer", null: true)
    ]
    testRepo.exec(createTableSql("migrate_test", cols, pdSqlite))
    testRepo.exec("INSERT INTO `migrate_test` (`title`, `count`) VALUES (?, ?)", @["Hello", "42"])
    let rows = testRepo.queryRaw("SELECT * FROM `migrate_test`")
    check rows.len == 1
    check rows[0][1] == "Hello"
