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
