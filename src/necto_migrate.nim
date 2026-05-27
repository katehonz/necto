## Necto Migration CLI
##
## Entry point за `nimble migrate`.
## Очаква в текущата директория да има:
##   - migrations.nim (който import-ва всички миграции)
##   - конфигурация за Repo в config.nims или env vars
##
## Употреба:
##   nimble migrate          # изпълнява всички pending
##   nimble migrate --step 2 # изпълнява 2 pending

import std/[os, strutils]
import necto
import necto/adapters/postgres

# --- Зареждане на миграции ---
# Потребителят трябва да създаде migrations.nim в корена на проекта,
# който import-ва всички миграционни файлове:
#   import migrations/20260526120000_create_users
#   import migrations/20260526130000_create_posts

when fileExists("../migrations.nim"):
  include ../migrations
else:
  echo "⚠ No migrations.nim found in current directory."
  echo "  Create a migrations.nim file that imports all your migration files."

# --- Repo конфигурация (от env vars) ---

proc getEnvOrDefault(key, default: string): string =
  result = getEnv(key)
  if result.len == 0:
    result = default

proc buildRepo(): Repo =
  let adapter = newPostgresAdapter(
    getEnvOrDefault("NECTO_DB_HOST", "localhost"),
    getEnvOrDefault("NECTO_DB_USER", "postgres"),
    getEnvOrDefault("NECTO_DB_PASS", "pas+123"),
    getEnvOrDefault("NECTO_DB_NAME", "necto_test"),
    port = parseInt(getEnvOrDefault("NECTO_DB_PORT", "5432")),
    poolSize = 5
  )
  result = newRepo(adapter)

# --- Команда ---

when isMainModule:
  let repo = buildRepo()
  let migrator = newMigrator(repo)

  migrator.bootstrap()

  let args = commandLineParams()
  var steps = 0

  # Парсване на --step N и --no-lock
  for i, arg in args:
    if arg == "--step" and i + 1 < args.len:
      steps = parseInt(args[i + 1])
    elif arg == "--no-lock":
      migrator.disableLock = true

  if steps > 0:
    echo "Running up to ", steps, " migration(s)..."
  else:
    echo "Running all pending migrations..."

  discard migrator.migrate(steps)

  echo ""
  migrator.status()
