# Necto 🍯

> **Multi-database ORM for Nim 2.x**, inspired by [Ecto](https://hexdocs.pm/ecto/Ecto.html) (Elixir) and [Avram](https://github.com/luckyframework/avram) (Crystal).
>
> Supports **PostgreSQL**, **MariaDB/MySQL**, and **SQLite**.

```nim
import necto

# Composable, type-safe query (typed where values, pagination)
let users = repo.all(
  fromSchema(User)
    .where("age", Gte, 18)
    .orderBy("name", Asc)
    .paginate(1, 20)
)

# Changeset-driven writes
let cs = newChangeset(newUser(), {"name": "Ivan", "email": "ivan@test.com"}.toTable)
  .castFields(@["name", "email"])
  .validateRequired(@["name", "email"])
if cs.isValid:
  let user = repo.insert!(cs)

# Row-level multi-tenant + JWT auth
repo.setTenantId("acme")
let token = generateToken(defaultAuthConfig(secret), "user-1")
```

---

## Why Necto?

The Crystal community built **Avram** — an Ecto-like ORM that made the language productive for web development years earlier. The Nim community deserves the same level of abstraction.

| Feature | Necto | Norm | ActiveRecord |
|---------|-------|------|--------------|
| Repository Pattern | ✅ | ⚠️ | ❌ |
| Multi-database (PG, MySQL, SQLite) | ✅ | ❌ | ⚠️ |
| Multi-tenant (`schema_prefix` + `tenant_id`) | ✅ | ❌ | ⚠️ |
| Composable queries | ✅ | ❌ | ⚠️ |
| Subqueries (IN, EXISTS) | ✅ | ❌ | ✅ |
| CTEs (WITH) | ✅ | ❌ | ✅ |
| Row locks (`FOR UPDATE`) | ✅ | ❌ | ✅ |
| Changeset validations | ✅ | ❌ | ⚠️ |
| Type-safe preload | ✅ | ❌ | ❌ |
| Auto-preload macros | ✅ | ❌ | ❌ |
| Batch insert/update/delete | ✅ | ❌ | ✅ |
| Auth (bcrypt + JWT) + web helpers | ✅ | ❌ | ⚠️ |
| Pipe operator (Elixir-style) | ✅ | ❌ | ❌ |
| Reverse schema generation | ✅ | ❌ | ❌ |
| Lazy loading | ❌ *(by design)* | ✅ | ✅ |

**Necto does not do lazy loading.** You always know when and how queries run.

---

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Schema    │────▶│   Query     │────▶│    Repo     │
│  (structure)│     │  (request)  │     │ (connection)│
└─────────────┘     └─────────────┘     └──────┬──────┘
       │                                        │
       ▼                                        ▼
┌─────────────┐                       ┌─────────────┐
│  Changeset  │◀──────────────────────│   Adapter   │
│ (validation)│                       │ (PG/MySQL/  │
└─────────────┘                       │   SQLite)   │
                                      └─────────────┘
```

| Component | Responsibility | Analog |
|-----------|--------------|--------|
| **Schema** | Defines tables, fields, types, relations | Ecto.Schema |
| **Query** | Composable DSL for SELECT | Ecto.Query |
| **Changeset** | Cast, validation, change tracking | Ecto.Changeset |
| **Repo** | Connection, pool, transactions | Ecto.Repo |
| **Migration** | Schema versioning | Ecto.Migration |

---

## Quick Start

### Installation

```bash
nimble install necto
```

Or locally:

```bash
git clone https://github.com/katehonz/necto.git
cd necto
nimble develop
```

**Requirements:** Nim >= 2.0.0, `db_connector` (installed automatically). One of: PostgreSQL >= 12, MariaDB/MySQL >= 10.2, or SQLite >= 3.25.

### 1. Define a Repo

**PostgreSQL:**
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

**MariaDB / MySQL:**
```nim
import necto
import necto/adapters/mariadb

necto_repo AppRepo:
  adapter MariaDbAdapter
  host "localhost"
  port 3306
  user "root"
  password "pas+123"
  database "my_app"
  pool_size 10
```

**SQLite:**
```nim
import necto
import necto/adapters/sqlite

necto_repo AppRepo:
  adapter SqliteAdapter
  database "my_app.db"  # or ":memory:" for tests
  pool_size 1
```

```nim
let repo = apprepoInstance
```

### 2. Define a Schema

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string {.not_null, unique.}
  field age: int
  timestamps
```

### 3. Query

```nim
# All users
let all = repo.all(fromSchema(User))

# Filtering and sorting
let adults = repo.all(
  fromSchema(User)
    .where("age", Gte, "18")
    .orderBy("name", Asc)
    .limit(10)
)

# Single result
let maybe = repo.one(fromSchema(User).where("email", Eq, "ivan@test.com"))

# Count
let count = repo.count(fromSchema(User).where("active", Eq, "true"))

# Subqueries (IN / EXISTS)
let sq = fromSchema(Order).select("user_id").where("total", Gt, "100").subquery()
let bigSpenders = repo.all(
  fromSchema(User).whereIn("id", sq)
)

# Full-Text Search
let articles = repo.all(
  fromSchema(Article)
    .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim orm"))
    .orderByTsRank("search_vector", plaintoTsQuery("simple", "nim orm"), Desc)
    .limit(10)
)
```

### 4. Insert / Update / Delete

```nim
# INSERT
var cs = newChangeset(newUser(), {"name": "Ivan", "email": "ivan@test.com"}.toTable)
cs = cs.castFields(@["name", "email"])
  .validateRequired(@["name", "email"])
let user = repo.insert!(cs)

# UPDATE
var cs2 = newChangeset(user, {"name": "Ivan Petrov"}.toTable)
cs2 = cs2.castFields(@["name"])
let updated = repo.update!(cs2)

# DELETE
var cs3 = newChangeset(updated, initTable[string, string]())
cs3.changes["id"] = $updated.id
repo.delete!(cs3)

# Batch insert
var css: seq[Changeset[User]] = @[]
for name in @["Alice", "Bob", "Charlie"]:
  var cs = newChangeset(newUser(), {"name": name}.toTable)
  cs = cs.castFields(@["name"])
  css.add(cs)
let users = repo.insert_all(css)  # Single batch query, RETURNING *

# Batch update
let updated = repo.update_all(
  fromSchema(User).where("active", Eq, "false"),
  {"active": "true"}.toTable
)

# Batch delete
let deleted = repo.delete_all(
  fromSchema(User).where("last_login", Lt, "2020-01-01")
)

# Pipe operator (Elixir-style)
let adults = User
  |> fromSchema
  |> where("age", Gte, "18")
  |> orderBy("name", Asc)
  |> limit(10)
  |> repo.all
```

### 5. Transactions

```nim
repo.transaction proc() =
  let user = repo.insert!(newChangeset(newUser(), params))
  let post = repo.insert!(newChangeset(newPost(), params2))
  # Exception → automatic ROLLBACK
```

### 6. Associations & Preload

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  belongs_to author: User
  timestamps

# Load posts
let posts = repo.all(fromSchema(Post).orderBy("id", Asc))

# Batch preload authors (2 queries, N+1 safe)
let authors = preloadBelongsTo[Post, User](repo, posts)
for p in posts:
  echo authors[p.author_id].name

# Automatic preload (even more convenient)
let postsWithAuthors = repo.allWithPreload(
  fromSchema(Post).orderBy("id", Asc),
  "author"
)
# Posts are loaded; authors are batch-preloaded automatically

# Multiple associations at once
let usersWithPosts = repo.allWithPreload(
  fromSchema(User).where("active", Eq, "true"),
  "posts", "profile"
)
```

---

## Testing

```bash
# PostgreSQL — create test database first
PGPASSWORD='pas+123' psql -U postgres -c "CREATE DATABASE necto_test;"
nimble test_postgres

# MariaDB — requires running server on localhost:3306, DB "necto", user "root"/"pas+123"
nimble test_mariadb

# SQLite — in-memory, no setup needed
nimble test_sqlite
```

---

## Documentation

- [Getting Started](./docs/getting_started.md)
- [Schema](./docs/schema.md)
- [Query DSL](./docs/query.md)
- [Changesets](./docs/changeset.md)
- [Associations & Preload](./docs/associations.md)
- [Migrations](./docs/migrations.md)

Full architecture plan: [PLAN.md](./PLAN.md)  
Bulgarian README: [README_BG.md](./README_BG.md)

---

## Roadmap

| Version | Goal |
|---------|------|
| **0.1.0** | ✅ Skeleton, schema, repo, adapter, migrations |
| **0.2.0** | ✅ Type-safe query DSL, bound parameters, transaction context, preload |
| **0.3.0** | ✅ Advanced changeset, batch ops, pipe operator, auto-preload, reverse schema generation |
| **0.4.0** | ✅ Multi-database: PostgreSQL, MariaDB/MySQL, SQLite; dialect-aware migrations |
| **0.5.0** | Performance: prepared statements, compiled query cache, pool metrics |
| **1.0.0** | Async support, read replicas, production ready |

---

## License

MIT License — see [LICENSE](LICENSE).

---

*Built with ❤️ by the Nim community. Inspired by Ecto and Avram.*
