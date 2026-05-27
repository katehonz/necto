# Getting Started

This guide walks you through setting up Necto and performing basic CRUD operations.

## Prerequisites

- Nim >= 2.0.0
- PostgreSQL >= 12
- A running PostgreSQL server with a database and user

## Installation

Add to your `.nimble` file:

```nim
requires "necto >= 0.2.0"
```

Or install locally:

```bash
git clone https://github.com/katehonz/necto.git
cd necto
nimble develop
```

## Project Structure

A typical Necto project looks like this:

```
my_app/
├── my_app.nimble
├── src/
│   ├── my_app.nim
│   ├── models/
│   │   ├── user.nim
│   │   └── post.nim
│   └── repo.nim
├── migrations/
│   └── m20260526120000_create_users.nim
└── migrations.nim
```

## 1. Define the Repo

Create `src/repo.nim`:

```nim
import necto
import necto/adapters/postgres

necto_repo AppRepo:
  adapter PostgresAdapter
  host "localhost"
  port 5432
  user "postgres"
  password "pas+123"
  database "my_app"
  pool_size 10
```

`apprepoInstance` is created automatically and is ready to use.

## 2. Define a Schema

Create `src/models/user.nim`:

```nim
import necto

necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string {.not_null, unique.}
  field age: int
  timestamps
```

This generates:
- `User` — a `ref object` type
- `UserSchema` — `SchemaMeta` constant
- `newUser()` — constructor
- `loadUser(row)` — row loader
- `getFieldVal` / `setFieldVal` / `getFieldValRuntime` — field helpers

## 3. Create a Table

Generate a migration:

```bash
nimble gen_migration
# or manually:
nim c -r --path:src src/necto_gen_migration.nim
```

Then write the migration in `migrations/`:

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

Register it in `migrations.nim`:

```nim
include migrations/m20260526120000_create_users
```

Run migrations:

```bash
nimble migrate
```

## 4. CRUD in Code

```nim
import necto
import repo
import models/user

let repo = apprepoInstance

# CREATE
var cs = newChangeset(newUser(), {
  "name": "Alice",
  "email": "alice@test.com",
  "age": "30"
}.toTable)
cs = cs.castFields(@["name", "email", "age"])
  .validateRequired(@["name", "email"])
let user = repo.insert(cs)

# READ
let users = repo.all(
  fromSchema(User).where("age", Gte, "18").orderBy("name", Asc)
)

# UPDATE
var cs2 = newChangeset(user, {"name": "Alice Smith"}.toTable)
cs2 = cs2.castFields(@["name"])
let updated = repo.update(cs2)

# DELETE
var cs3 = newChangeset(updated, initTable[string, string]())
cs3.changes["id"] = $updated.id
repo.delete(cs3)

# Batch insert
var css: seq[Changeset[User]] = @[]
for name in @["Alice", "Bob", "Charlie"]:
  var c = newChangeset(newUser(), {"name": name}.toTable)
  c = c.castFields(@["name"])
  css.add(c)
let newUsers = repo.insert_all(css)

# Pipe syntax
let adults = User
  |> fromSchema
  |> where("age", Gte, "18")
  |> orderBy("name", Asc)
  |> repo.all
```

## 5. Verify Your Schema (optional but recommended)

Add `verify` to catch schema mismatches at startup:

```nim
necto_schema User:
  table "users"
  verify                       # ← enable verification
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string {.not_null, unique.}
  timestamps
```

Then compile with:

```bash
NECTO_VERIFY=1 nim c -r src/my_app.nim
```

If the database schema matches your Nim definitions, the app starts normally.
If there's a mismatch (missing column, wrong type, missing constraint), the
app stops immediately with a clear error message — before any queries execute.

For CI/CD, use the standalone CLI tool:

```bash
nimble verify -- --table=users --field=id:int64:bigint:pk:notnull ...
```

See [Schema Verification](./verification.md) for details.

## 6. Next Steps

- [Schema](./schema.md) — fields, types, associations, soft deletes, embedded schemas, multi-tenant, typed JSONB
- [Query DSL](./query.md) — where, joins, aggregates, CTEs, FTS, JSONB, window functions, subqueries, pipe
- [Changesets](./changeset.md) — cast, validations, constraints, batch operations
- [Associations & Preload](./associations.md) — belongs_to, has_many, has_one, many_to_many, build_assoc, N+1 safe
- [Migrations](./migrations.md) — up/down, change blocks, checksum validation, advisory locks
- [Schema & Query Verification](./verification.md) — compile-time DB checks, query validation, CI/CD integration
- [Migrations](./migrations.md) — DSL, versioning, rollback
- [Benchmarks](./benchmarks.md) — performance comparison vs raw SQL
