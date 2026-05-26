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

## SQL Injection Safety

Necto never interpolates values into SQL strings. All values are passed as `$N` placeholders via `pqexecParams`:

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
