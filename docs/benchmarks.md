# Benchmarks

Necto includes a benchmark suite comparing ORM operations against raw `db_postgres` queries.

## Running Benchmarks

```bash
nim c -r -d:release --path:src benchmarks/necto_bench.nim
```

Requires PostgreSQL on `localhost:5432`, user `postgres`, password `pas+123`, database `necto_test`.

## What Gets Measured

5 benchmarks, each run multiple times with warmup:

| Benchmark | Measures |
|-----------|----------|
| SELECT 1000 rows | Schema row loading with type conversion |
| SELECT WHERE age > 40 | Filtered query with parameter binding |
| SELECT by PK | Primary key lookup |
| INSERT single row | Changeset validation + INSERT + RETURNING |
| COUNT all rows | Aggregate query |

## Interpretation

The raw SQL path uses a single shared `db_postgres` connection (no pool overhead).
Necto uses its connection pool and prepared statement cache.

**Expected results (release build, local PostgreSQL):**

- **INSERT: ~9% overhead** — changeset validation + RETURNING overhead
- **PK lookup: ~25% overhead** — type conversion (`loadValue`) + ref object allocation
- **COUNT: Necto is faster** — prepared statement cache beats simple protocol
- **SELECT 1000 rows: higher overhead** — typed row loading vs raw strings

### Why SELECT shows higher overhead

Raw `db_postgres` returns `seq[seq[string]]` — just strings.
Necto returns `seq[YourType]` with type conversion for every column:

```nim
# Raw: O(n) string copies
for row in db.getAllRows(sql(...)): rows.add(row)

# Necto: O(n × fields) type conversions
for row in rows: result.add(loadValue(row[0], int64), loadValue(row[1], string), ...)
```

This is the price of type safety. Ecto and Avram have the same characteristic.

## Comparing Against Ecto / Avram

Coming in Phase 4. The benchmark suite is ready to be run against:

- Raw `db_postgres` (already done)
- Elixir Ecto + Postgrex
- Crystal Avram + pg

## Custom Configuration

Edit `benchmarks/necto_bench.nim` to change:
- `const ITERS` — iterations per benchmark
- Connection parameters
- Table schema

The benchmark harness (`timeIt` template, `addResult` proc) is reusable for custom benchmarks.
