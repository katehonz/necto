## Necto Migrator
##
## Runner за миграции. Следи `necto_schema_migrations` таблица,
## сравнява с регистрираните миграции и изпълнява pending.
##
## Употреба:
##   let migrator = newMigrator(myRepo)
##   migrator.bootstrap()
##   migrator.migrate()      # изпълнява всички pending миграции
##   migrator.rollback(1)    # отменя последната миграция
##   migrator.status()       # показва статус на всички

import std/[strutils, times, sequtils, sets, algorithm, os]
import ./migration
import ./repo
import ./errors

export migration, repo, errors

# --- Migrator тип ---

type
  Migrator* = ref object
    repo*: Repo
    migrationsTable*: string

proc newMigrator*(repo: Repo, migrationsTable: string = "necto_schema_migrations"): Migrator =
  ## Създава нов Migrator с подаден Repo.
  Migrator(repo: repo, migrationsTable: migrationsTable)

# --- Bootstrap ---

proc bootstrap*(mig: Migrator) =
  ## Създава таблицата за миграции ако не съществува.
  ## Добавя checksum колона ако липсва (backward compatibility).
  mig.repo.exec("""
    CREATE TABLE IF NOT EXISTS """ & "\"" & mig.migrationsTable & "\"" & """ (
      version TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      checksum TEXT,
      inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    )
  """)
  # Добавяме checksum колона ако таблицата е от стара версия
  try:
    mig.repo.exec("ALTER TABLE \"" & mig.migrationsTable & "\" ADD COLUMN IF NOT EXISTS checksum TEXT")
  except DatabaseError:
    discard

# --- DB queries ---

proc appliedMigrations*(mig: Migrator): seq[(string, string, string)] =
  ## Връща списък с приложените миграции от БД.
  ## Tuple: (version, name, checksum)
  let rows = mig.repo.queryRaw(
    "SELECT version, name, COALESCE(checksum, '') FROM \"" & mig.migrationsTable &
    "\" ORDER BY version ASC"
  )
  for row in rows:
    if row.len >= 3:
      result.add((row[0], row[1], row[2]))
    elif row.len >= 2:
      result.add((row[0], row[1], ""))

proc recordMigration*(mig: Migrator, version, name, checksum: string) =
  ## Записва миграция като приложена.
  mig.repo.exec(
    "INSERT INTO \"" & mig.migrationsTable &
    "\" (version, name, checksum) VALUES ($1, $2, $3)",
    @[version, name, checksum]
  )

proc removeMigration*(mig: Migrator, version: string) =
  ## Премахва запис за миграция (при rollback).
  mig.repo.exec(
    "DELETE FROM \"" & mig.migrationsTable &
    "\" WHERE version = $1",
    @[version]
  )

# --- Core логика ---

proc pendingMigrations*(mig: Migrator): seq[MigrationEntry] =
  ## Връща миграциите които още не са приложени.
  let applied = mig.appliedMigrations()
  let appliedVersions = applied.mapIt(it[0]).toHashSet()
  for entry in allMigrations():
    if entry.version notin appliedVersions:
      result.add(entry)

proc lastApplied*(mig: Migrator): seq[(string, string, string)] =
  ## Връща последните N приложени миграции (за rollback).
  let all = mig.appliedMigrations()
  result = all

# --- Операции ---

proc migrate*(mig: Migrator, steps: int = 0): int =
  ## Изпълнява pending миграции.
  ##
  ## Ако steps == 0: изпълнява всички pending.
  ## Ако steps > 0: изпълнява точно steps на брой.
  ##
  ## Връща броя изпълнени миграции.
  let pending = mig.pendingMigrations()
  if pending.len == 0:
    echo "No pending migrations."
    return 0

  var toRun = pending
  if steps > 0 and steps < toRun.len:
    toRun = toRun[0..<steps]

  echo "Running ", toRun.len, " migration(s)..."
  for entry in toRun:
    let migration = entry.factory()
    let ver = entry.version
    let nm = entry.name
    let cs = entry.checksum
    echo "  → ", ver, " ", nm

    mig.repo.transaction proc() =
      migration.up(mig.repo)
      mig.recordMigration(ver, nm, cs)

    echo "    ✓ applied"

  echo "Done. ", toRun.len, " migration(s) applied."
  result = toRun.len

proc rollback*(mig: Migrator, steps: int = 1): int =
  ## Отменя последните N миграции.
  ## Валидация на checksum — ако миграцията е променена след прилагане,
  ## rollback се прекратява с грешка за сигурност.
  ##
  ## Връща броя отменени миграции.
  let applied = mig.appliedMigrations()
  if applied.len == 0:
    echo "No migrations to rollback."
    return 0

  var toRollback: seq[(string, string, string)]
  if steps >= applied.len:
    toRollback = applied
  else:
    toRollback = applied[^(steps)..^1]

  toRollback.reverse()  # от най-новата към най-старата

  echo "Rolling back ", toRollback.len, " migration(s)..."
  for (version, name, dbChecksum) in toRollback:
    # Намираме миграцията по version
    var migration: Migration = nil
    var registeredChecksum = ""
    for entry in allMigrations():
      if entry.version == version:
        migration = entry.factory()
        registeredChecksum = entry.checksum
        break

    if migration == nil:
      echo "  ⚠ Migration ", version, " not found in registry, skipping."
      continue

    # Checksum validation
    if dbChecksum.len > 0 and registeredChecksum.len > 0 and dbChecksum != registeredChecksum:
      raise newException(MigrationError,
        "Checksum mismatch for migration " & version & 
        ": the migration file has been modified since it was applied. " &
        "Rollback aborted for safety. Expected: " & dbChecksum & 
        ", got: " & registeredChecksum)

    let v = version
    let n = name
    echo "  ← ", v, " ", n
    mig.repo.transaction proc() =
      migration.down(mig.repo)
      mig.removeMigration(v)
    echo "    ✓ rolled back"

  echo "Done. ", toRollback.len, " migration(s) rolled back."
  result = toRollback.len

proc redo*(mig: Migrator, steps: int = 1) =
  ## Преизпълнява последните N миграции (down + up).
  let rolled = mig.rollback(steps)
  if rolled > 0:
    discard mig.migrate(rolled)

proc status*(mig: Migrator) =
  ## Показва статус на всички миграции.
  let applied = mig.appliedMigrations()
  let appliedVersions = applied.mapIt(it[0]).toHashSet()

  echo "\nMigration Status"
  echo "================"
  echo "Total registered: ", allMigrations().len
  echo "Applied: ", applied.len
  echo "Pending: ", allMigrations().len - applied.len
  echo ""

  if allMigrations().len == 0:
    echo "  (no migrations registered)"
    return

  for entry in allMigrations():
    let status = if entry.version in appliedVersions: "✓ applied" else: "• pending"
    let csIndicator = if entry.checksum.len > 0: " 🔒" else: ""
    echo "  ", entry.version, "  ", entry.name, "  [", status, "]", csIndicator

proc reset*(mig: Migrator) =
  ## Rollback всички миграции (опасно! за dev/test).
  let applied = mig.appliedMigrations()
  if applied.len > 0:
    discard mig.rollback(applied.len)

proc generateMigrationFile*(name: string, dir: string = "migrations"): string =
  ## Генерира skeleton на миграционен файл.
  ## Връща пътя до създадения файл.
  let timestamp = now().format("yyyyMMddHHmmss")
  let filename = "m" & timestamp & "_" & name.toLowerAscii() & ".nim"
  let filepath = dir / filename

  createDir(dir)

  let content = """import necto
import necto/migration

necto_migration """ & name & """, \"""" & timestamp & """\":
  up:
    # TODO: write your migration here
    # createTable repo, "new_table", cols(pk("id"), col("name", "text", nullable = false))
    #   & timestamps()
    discard

  down:
    # TODO: write rollback here
    # dropTable repo, "new_table"
    discard
"""
  writeFile(filepath, content)
  result = filepath
