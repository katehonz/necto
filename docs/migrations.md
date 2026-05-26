# Migrations

Necto migrations are versioned Nim modules with `up` and `down` blocks.

## Creating a Migration

```bash
nimble gen_migration
```

Or manually:

```bash
nim c -r --path:src src/necto_gen_migration.nim
```

This generates a file like `migrations/m20260526120000_create_users.nim`.

## Writing a Migration

```nim
import necto
import necto/migration

necto_migration CreateUsers, "20260526120000":
  up:
    createTable repo, "users", [
      pk("id"),
      col("name", "text", nullable = false),
      col("email", "text", nullable = false),
      col("age", "integer"),
      timestamps()
    ]
    createIndex repo, "users", @["email"], unique = true

  down:
    dropTable repo, "users"
```

## DSL Helpers

| Helper | SQL Generated |
|--------|---------------|
| `pk(name, dbType = "bigserial")` | `BIGSERIAL PRIMARY KEY` |
| `col(name, dbType, nullable, default, unique, reference)` | Column definition |
| `timestamps()` | `created_at` + `updated_at` with `DEFAULT NOW()` |
| `createTable repo, name, columns` | `CREATE TABLE IF NOT EXISTS` |
| `dropTable repo, name` | `DROP TABLE IF EXISTS` |
| `createIndex repo, table, columns, unique, name` | `CREATE INDEX IF NOT EXISTS` |
| `dropIndex repo, table, columns, name` | `DROP INDEX IF EXISTS` |
| `addColumn repo, table, name, dbType, ...` | `ALTER TABLE ... ADD COLUMN` |
| `dropColumn repo, table, name` | `ALTER TABLE ... DROP COLUMN` |
| `renameColumn repo, table, old, new` | `ALTER TABLE ... RENAME COLUMN` |

## Registration

Create `migrations.nim` in the project root:

```nim
include migrations/m20260526120000_create_users
include migrations/m20260526130000_create_posts
```

## Running Migrations

```bash
# Run all pending
nimble migrate

# Run specific number
nimble migrate  # uses default: all

# Rollback last
nimble rollback

# Check status
nimble migrate_status
```

## How It Works

1. **Bootstrap** — creates `necto_schema_migrations` table if missing
2. **Compare** — reads registered migrations vs. applied versions
3. **Run** — executes `up` in a transaction, records the version
4. **Rollback** — executes `down`, removes the version record
