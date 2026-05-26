## Necto Gen Migration CLI
##
## Entry point за `nimble gen_migration`.
## Генерира нов миграционен файл.

import std/[os, strutils]
import necto/migrator

when isMainModule:
  let args = commandLineParams()

  if args.len == 0:
    echo "Usage: nimble gen_migration <MigrationName>"
    echo "Example: nimble gen_migration CreatePosts"
    quit(1)

  let name = args[0]
  let filepath = generateMigrationFile(name)
  echo "Generated migration: ", filepath
  echo ""
  echo "Add 'import ", filepath.replace(".nim", "").replace("/", "/"), "' to your migrations.nim file."
