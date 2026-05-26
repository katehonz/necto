# Package
version       = "0.1.0"
author        = "Nim Community"
description   = "Ecto-inspired ORM for Nim with type-safe queries, changesets and migrations"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"

# --- Migration tasks ---

task migrate, "Run pending migrations":
  exec "nim c -r --path:src src/necto_migrate.nim"

task rollback, "Rollback last migration":
  exec "nim c -r --path:src src/necto_rollback.nim"

task gen_migration, "Generate a new migration file":
  exec "nim c -r --path:src src/necto_gen_migration.nim"

task migrate_status, "Show migration status":
  exec "nim c -r --path:src src/necto_status.nim"

task gen_schema, "Generate schema from existing PostgreSQL table":
  echo "Run directly: nim c -r --path:src src/necto_gen_schema.nim --table TABLE_NAME"
  echo "Options: --table, --output, --module, --schema, --host, --port, --user, --password, --database"

# --- Test tasks ---

task test, "Run all test suites":
  exec "nimble test_postgres"

task test_postgres, "Run PostgreSQL tests":
  exec "testament pattern 'tests/t_*.nim'"
