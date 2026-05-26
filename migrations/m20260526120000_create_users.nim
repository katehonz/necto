## Примерна миграция: CreateUsers
import necto
import necto/migration

necto_migration CreateUsers, "20260526120000":
  up:
    createTable repo, "users", cols(pk("id"), col("name", "text", nullable = false),
      col("email", "text", nullable = false), col("age", "integer")) & timestamps()
    createIndex repo, "users", @["email"], unique = true

  down:
    dropTable repo, "users"
