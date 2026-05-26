## Necto Status CLI
##
## Entry point за `nimble migrate_status`.
## Показва статус на всички миграции.

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
  migrator.status()
