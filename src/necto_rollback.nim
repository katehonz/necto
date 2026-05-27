## Necto Rollback CLI
##
## Entry point за `nimble rollback`.
## Отменя последната миграция (опционално N стъпки).

import std/[os, strutils]
import necto
import necto/adapters/postgres

include ../migrations

proc buildRepo(): Repo =
  let adapter = newPostgresAdapter(
    getEnv("NECTO_DB_HOST", "localhost"),
    getEnv("NECTO_DB_USER", "postgres"),
    getEnv("NECTO_DB_PASS", "pas+123"),
    getEnv("NECTO_DB_NAME", "necto_test"),
    port = parseInt(getEnv("NECTO_DB_PORT", "5432")),
    poolSize = 5
  )
  result = newRepo(adapter)

when isMainModule:
  let repo = buildRepo()
  let migrator = newMigrator(repo)

  let args = commandLineParams()
  var steps = 1
  for i, arg in args:
    if arg == "--step" and i + 1 < args.len:
      steps = parseInt(args[i + 1])
    elif arg == "--no-lock":
      migrator.disableLock = true

  echo "Rolling back ", steps, " migration(s)..."
  discard migrator.rollback(steps)
  echo ""
  migrator.status()
