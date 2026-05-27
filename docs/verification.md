# Schema & Query Verification

Necto provides two layers of database verification, both activated with `-d:nectoVerify`:

1. **Schema Verification** — checks that `necto_schema` definitions match the real database
2. **Query Verification** — checks that queries reference real tables and columns

Both are **Necto superpowers** — possible because Nim compiles to native code
and can connect to a database at startup with zero overhead when disabled.

---

# Schema Verification

Schema verification catches mismatches between your Nim schema definitions
and the actual PostgreSQL database *before* any queries execute.

## Quick Start

Add `verify` to any `necto_schema` block:

```nim
necto_schema User:
  table "users"
  verify
  field id: int64 {.primary_key, auto_increment.}
  field email: string {.not_null, unique.}
  field name: string
  timestamps
```

Then compile with the verification flag:

```bash
NECTO_VERIFY=1 nim c -r my_app.nim
```

When verification passes:

```
═══ VERIFICATION ERRORS: users ═══
  (none)
─── VERIFICATION WARNINGS: users ───
  (none)
✅ All good — your app starts normally.
```

When it fails, your app stops immediately with clear messages — no runtime
surprises in production.

## What Gets Checked

| Check | Severity | Description |
|-------|----------|-------------|
| Table exists | **ERROR** | `information_schema.tables` — table must exist in `public` schema |
| Column exists | **ERROR** | Each field must have a matching column in the table |
| Type compatible | WARNING | Column type must be compatible (aliases accepted) |
| NOT NULL match | **ERROR** | Schema `{.not_null.}` must match database `NOT NULL` |
| PRIMARY KEY | **ERROR** | Schema `{.primary_key.}` must have a PK constraint in the database |
| UNIQUE constraint | WARNING | Schema `{.unique.}` should have a UNIQUE constraint |
| Extra DB columns | WARNING | Columns in database but not in schema are flagged |

### Type Compatibility

Necto recognizes common PostgreSQL type aliases as compatible:

| Schema declares | Database has | Compatible? |
|----------------|-------------|-------------|
| `text` | `varchar`, `character varying` | ✅ |
| `integer` | `int4`, `int` | ✅ |
| `bigint` | `int8` | ✅ |
| `boolean` | `bool` | ✅ |
| `jsonb` | `json` | ✅ (and vice versa) |
| `text` | `integer` | ❌ — type mismatch warning |

The full compatibility table is in `src/necto/schema_verifier.nim` (`isTypeCompatible`).

## Activation Methods

### 1. Per-Schema `verify` Statement (recommended)

```nim
necto_schema User:
  table "users"
  verify          # ← only this schema is checked
  field id: int64 {.primary_key.}
```

Only schemas with `verify` are checked. Compile with `-d:nectoVerify` or
`NECTO_VERIFY=1`.

### 2. Programmatic API

Call `verifySchema()` directly for custom workflows:

```nim
import necto/schema_verifier

let fields = @[
  SchemaFieldInfo(nimName: "id", dbColumn: "id", nimType: "int64",
                   dbType: "bigint", isPrimaryKey: true, isNullable: false),
  SchemaFieldInfo(nimName: "name", dbColumn: "name", nimType: "string",
                   dbType: "text", isPrimaryKey: false, isNullable: false),
]

let result = verifySchema(
  "localhost", 5432, "postgres", "my_password", "my_app",
  "users", fields
)

if result.errors.len > 0:
  echo formatResult(result)
  quit(1)
```

### 3. Standalone CLI Tool

For CI/CD pipelines and pre-commit hooks — no Nim schema file needed:

```bash
nim c -r --path:src src/necto_verify.nim \
  --table=users \
  --field=id:int64:bigint:pk:notnull \
  --field=name:string:text:notnull \
  --field=email:string:text:unique \
  --host=localhost \
  --port=5432 \
  --user=postgres \
  --password=secret \
  --database=my_app
```

Or via nimble:

```bash
nimble verify -- --table=users --field=id:int64:bigint:pk:notnull ...
```

Field format: `name:nimType:dbType[:flags]`

| Flag | Meaning |
|------|---------|
| `pk` | Primary key |
| `notnull` | NOT NULL |
| `unique` | UNIQUE constraint |

Exit codes: `0` = pass, `1` = errors found.

## Database Configuration

The verifier reads these environment variables (same as the rest of Necto):

| Variable | Default | Description |
|----------|---------|-------------|
| `PGHOST` | `localhost` | PostgreSQL host |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGUSER` | `postgres` | Database user |
| `PGPASSWORD` | *(empty)* | Database password |
| `PGDATABASE` | `necto_test` | Database name |

## CI/CD Integration

### GitHub Actions

```yaml
- name: Verify database schema
  run: |
    nimble verify -- \
      --host=${{ secrets.DB_HOST }} \
      --user=${{ secrets.DB_USER }} \
      --password=${{ secrets.DB_PASSWORD }} \
      --database=${{ secrets.DB_NAME }} \
      --table=users \
      --field=id:int64:bigint:pk:notnull \
      --field=email:string:text:notnull:unique \
      --field=name:string:text:notnull
  env:
    PGPASSWORD: ${{ secrets.DB_PASSWORD }}
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit
echo "Verifying database schemas..."
NECTO_VERIFY=1 nim c -r --path:src src/my_app.nim
```

## How It Works

1. The `verify` statement in `necto_schema` generates a `verifyXxxSchema()` proc
2. This proc is called **at module initialization** when compiled with `-d:nectoVerify`
3. The proc connects to PostgreSQL and queries:
   - `information_schema.tables` — table existence
   - `information_schema.columns` — column names and types
   - `information_schema.table_constraints` — PK, FK, UNIQUE constraints
4. Results are compared against the Nim schema definition
5. Errors cause `quit(1)` before `main()` runs

When `-d:nectoVerify` is **not** set, the verification code is completely
eliminated by the compiler — zero runtime overhead.

## Limitations

- **PostgreSQL only** — verification is tied to `information_schema`
- **`public` schema only** — cross-schema checks not yet supported
- **Foreign key verification** — FK constraint names are checked but not the
  referenced table/column (on the roadmap)
- **Compile-time vs startup** — verification runs at app startup, not during
  Nim compilation. This means you need a running database during compilation
  when `-d:nectoVerify` is active.

# Query Verification

Query verification validates that your Query DSL calls reference real tables
and columns before executing.

## Quick Start

```nim
import necto/query_verifier

let q = verifyQuery(User, fromSchema(User).where("age", Gt, "18"))
repo.all(q)
```

Compile with `-d:nectoVerify`:

```bash
NECTO_VERIFY=1 nim c -r my_app.nim
```

## What Gets Checked

| Check | Severity | Description |
|-------|----------|-------------|
| Table exists | **ERROR** | Query's target table must exist |
| Column exists | **ERROR** | Every column in WHERE, SELECT, ORDER BY, aggregates must exist |
| SQL syntax | **ERROR** | PostgreSQL `EXPLAIN (FORMAT JSON)` validates the generated SQL |

When a query fails verification:

```
═══ QUERY VERIFY: users ═══
  SQL: SELECT * FROM "users" WHERE "agee" > $1 ORDER BY "name" ASC
  ERROR: Column 'agee' not found in 'users'
```

## Programmatic API

```nim
import necto/query_verifier

let q = fromSchema(User).where("age", Gt, "18")
let bq = q.toBoundQuery()
let cols = q.extractColumns()

let r = verifyQueryAgainstDb(
  "localhost", 5432, "postgres", "secret", "my_app",
  "users", cols, bq.sql
)

if r.errors.len > 0:
  echo formatQueryResult(r)
  quit(1)
```

## How It Works

1. `verifyQuery` is a template that wraps any `Query[T]`
2. When `-d:nectoVerify` is active, it calls `verifyQueryAgainstDb()` before the query executes
3. The verifier queries `information_schema.tables` and `information_schema.columns`
4. If the SQL is available, it runs `EXPLAIN (FORMAT JSON)` to validate syntax
5. Errors stop the program immediately

When the flag is not set, `verifyQuery` passes the query through with zero overhead.

---

## Roadmap

- [ ] True compile-time verification (via `staticExec` + external process)
- [ ] Foreign key target validation (referenced table and column)
- [ ] Check constraint verification
- [ ] Index existence verification
- [ ] Batch query verification (verify all queries at startup)
