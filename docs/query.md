# Query DSL

Necto queries are immutable, composable, and use `$N` parameter binding under the hood.

## Creating a Query

```nim
let q = fromSchema(User)
```

## Modifiers

All modifiers return a new `Query`; the original is unchanged.

### select

```nim
let q = fromSchema(User).select("id", "name")
```

### where

```nim
let q = fromSchema(User)
  .where("age", Gte, "18")
  .where("name", Like, "Ivan%")
```

Supported operators:

| Operator | SQL |
|----------|-----|
| `Eq` | `=` |
| `Ne` | `!=` |
| `Gt` | `>` |
| `Gte` | `>=` |
| `Lt` | `<` |
| `Lte` | `<=` |
| `Like` | `LIKE` |
| `Ilike` | `ILIKE` |
| `In` | `IN (...)` |
| `IsNull` | `IS NULL` |
| `NotNull` | `IS NOT NULL` |

Multiple `where` calls are joined with `AND`.

### orWhere

```nim
let q = fromSchema(User)
  .where("active", Eq, "true")
  .orWhere("role", Eq, "admin")
```

### orderBy

```nim
let q = fromSchema(User).orderBy("name", Asc)
let q2 = fromSchema(User).orderBy("created_at", Desc)
```

### limit / offset

```nim
let q = fromSchema(User).limit(10).offset(20)
```

### distinct

```nim
let q = fromSchema(User).setDistinct()
```

### Joins

```nim
let q = fromSchema(Post)
  .innerJoin("users", "posts.author_id = users.id")
  .leftJoin("comments", "posts.id = comments.post_id")
```

### Aggregates

```nim
let q = fromSchema(User).count()
let q2 = fromSchema(Order).sum("amount", "total")
let q3 = fromSchema(Product).avg("price")
let q4 = fromSchema(User).groupBy("role").count()
```

### whereIt — Compile-time field checking

```nim
let q = fromSchema(User).whereIt(age > 18 and name == "Ivan")
```

Checks that `age` and `name` are real fields at compile-time. Supports `and`/`or`, `like`, `ilike`, `isNil`, `isNotNil`.

## Running Queries

### all

```nim
let users = repo.all(fromSchema(User).where("active", Eq, "true"))
```

### one

Returns `Option[T]`.

```nim
let maybeUser = repo.one(fromSchema(User).where("email", Eq, "a@b.com"))
if maybeUser.isSome:
  echo maybeUser.get().name
```

### count

```nim
let total = repo.count(fromSchema(User))
let active = repo.count(fromSchema(User).where("active", Eq, "true"))
```

## Compiled Query Cache

Pre-compute a query's SQL once and reuse it. Useful for queries executed in hot loops.

### compileQuery

```nim
let allUsersQ = compileQuery(fromSchema(User).orderBy("name", Asc))
echo allUsersQ.sql   # "SELECT * FROM \"users\" ORDER BY \"name\" ASC"
echo allUsersQ.args  # @[]
```

The result is a `BoundQuery` (SQL + args). Cache it in a `let` and pass to your repo methods.

### querySql

Resolves all `$N` placeholders to `NULL` — useful for EXPLAIN verification and debugging:

```nim
let sql = querySql(fromSchema(User).where("age", Gt, "18").limit(10))
echo sql  # "SELECT * FROM \"users\" WHERE \"age\" > NULL LIMIT NULL"
```

## Query Verification

Validate queries against the database at startup. Catches typos in table/column names before any queries execute.

```nim
import necto/query_verifier

let q = verifyQuery(User, fromSchema(User).where("age", Gt, "18"))
```

When compiled with `-d:nectoVerify`:
- Checks the table exists
- Checks all referenced columns exist
- Validates SQL syntax via PostgreSQL `EXPLAIN`

```bash
NECTO_VERIFY=1 nim c -r my_app.nim
```

Invalid queries print clear errors and stop the program immediately. When the flag is not set, `verifyQuery` is a zero-overhead pass-through.

See [Schema & Query Verification](./verification.md) for full details.

## Pipe Operator

Necto supports Elixir-style piping for cleaner query chains:

```nim
let adults = User
  |> fromSchema
  |> where("age", Gte, "18")
  |> orderBy("name", Asc)
  |> limit(10)
  |> repo.all
```

The `|>` macro simply inserts the left-hand side as the first argument of the right-hand call.

## Subqueries

Subqueries work via `.subquery()` which wraps a `Query` into a `SubQuery[T]`. Placeholders are automatically renumbered when embedded in the outer query.

### whereIn / whereNotIn

```nim
let sq = fromSchema(Order).select("user_id").where("total", Gt, "100").subquery()
let users = repo.all(
  fromSchema(User).whereIn("id", sq)
)
# SELECT * FROM "users" WHERE "id" IN (SELECT "user_id" FROM "orders" WHERE "total" > $1)
```

```nim
let sq = fromSchema(Order).select("user_id").subquery()
let users = repo.all(
  fromSchema(User).whereNotIn("id", sq)
)
# Users with no orders
```

### whereExists / whereNotExists

```nim
let sq = fromSchema(Order).where("total", Gt, "100").subquery()
let users = repo.all(
  fromSchema(User).whereExists(sq)
)
```

### Multiple subqueries

You can use as many subqueries as you want — placeholders are renumbered automatically:

```nim
let sq1 = fromSchema(Order).where("total", Gt, "100").subquery()
let sq2 = fromSchema(Order).where("status", Eq, "shipped").subquery()
let q = fromSchema(User)
  .whereIn("id", sq1)
  .whereIn("id", sq2)
# $1 = 100, $2 = "shipped"
```

## CTEs (Common Table Expressions)

Chain `.withCte()` to add `WITH` clauses. Use `.joinCte()` for convenient joins.

```nim
let totals = fromSchema(Order)
  .select("user_id").sum("total", "total_spent").groupBy("user_id")

let q = fromSchema(User)
  .withCte("user_totals", totals)
  .joinCte("user_totals", "\"users\".\"id\"", "user_id")
```

Multiple CTEs are supported — placeholders are renumbered automatically across all CTE clauses and the outer query.

## Full-Text Search (FTS)

PostgreSQL `tsvector` / `tsquery` support via SQL fragments and Query builder methods.

### Query builders

```nim
let q = fromSchema(Article)
  .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim orm"))
  .orderByTsRank("search_vector", plaintoTsQuery("simple", "nim orm"), Desc)
  .limit(10)
```

Available query functions:
- `whereTsVectorMatches(field, tsq)` — `WHERE field @@ tsq`
- `orWhereTsVectorMatches(field, tsq)` — `OR WHERE field @@ tsq`
- `orderByTsRank(field, tsq, dir)` — `ORDER BY ts_rank(field, tsq)`
- `orderByTsRankCd(field, tsq, dir)` — `ORDER BY ts_rank_cd(field, tsq)`

### SQL Fragments

| Template | Generates |
|----------|-----------|
| `toTsVector("simple", "title")` | `to_tsvector('simple', "title")` |
| `plaintoTsQuery("simple", "nim orm")` | `plainto_tsquery('simple', $1)` |
| `phrasetoTsQuery("simple", "nim orm")` | `phraseto_tsquery('simple', $1)` |
| `websearchToTsQuery("simple", "nim -python")` | `websearch_to_tsquery('simple', $1)` |
| `toTsQuery("simple", "nim & tutorial")` | `to_tsquery('simple', $1)` |
| `tsRank(field, tsq)` | `ts_rank(field, tsq)` |
| `tsRankCd(field, tsq)` | `ts_rank_cd(field, tsq)` |

All fragments support parameter binding — values never leak into SQL strings.

## JSONB Query Operators

PostgreSQL JSONB operators as first-class query methods:

```nim
# @> contains
let q = fromSchema(User).whereJsonbContains("data", """{"role":"admin"}""")

# ? has key
let q2 = fromSchema(User).whereJsonbHasKey("tags", "urgent")

# ?| has any keys
let q3 = fromSchema(User).whereJsonbHasAnyKeys("tags", @["urgent", "vip"])

# ?& has all keys
let q4 = fromSchema(User).whereJsonbHasAllKeys("tags", @["urgent", "customer"])
```

### Type-safe JSONB paths (whereJsonbIt)

Compile-time JSONB path extraction:

```nim
let q = fromSchema(User).whereJsonbIt(profile.settings.theme == "dark")
# Generates: WHERE "profile" #>> '{settings,theme}' = $1
```

## Window Functions

Add window function SQL expressions to queries:

```nim
let q = fromSchema(Employee)
  .rowNumber(partitionBy = @["department"], orderByField = "salary", orderDir = Desc)
  .select("department", "name", "salary")
```

Available window functions: `rowNumber()`, `rank()`, `denseRank()`, `lag()`, `lead()`, `ntile()`, `firstValue()`, `lastValue()`, `nthValue()`. Window frame definitions are built with `over()` helper.

## SQL Injection Safety

Necto never interpolates values into SQL strings. All values are passed as `$N` placeholders via `pqexecParams` / `pqexecPrepared`:

```nim
# Generated SQL:
# SELECT * FROM "users" WHERE "age" >= $1 AND "name" LIKE $2
# Args: @["18", "Ivan%"]
```

You can inspect the bound query:

```nim
let bq = fromSchema(User).where("age", Gte, "18").toBoundQuery()
echo bq.sql
echo bq.args
```
