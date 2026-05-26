# Necto 🍯

> **PostgreSQL-first ORM for Nim 2.x**, inspired by [Ecto](https://hexdocs.pm/ecto/Ecto.html) (Elixir) and [Avram](https://github.com/luckyframework/avram) (Crystal).

```nim
import necto

# Composable, type-safe query
let users = repo.all(
  Query.fromSchema(User)
    .where("age", Gte, "18")
    .orderBy("name", Asc)
)

# Changeset-driven writes
let cs = newChangeset(newUser(), {"name": "Ivan", "email": "ivan@test.com"}.toTable)
  .castFields(@["name", "email"])
  .validateRequired(@["name", "email"])
if cs.isValid:
  let user = repo.insert!(cs)
```

---

## Why Necto?

The Crystal community built **Avram** — an Ecto-like ORM that made the language productive for web development years earlier. The Nim community deserves the same level of abstraction.

| Feature | Necto | Norm | ActiveRecord |
|---------|-------|------|--------------|
| Repository Pattern | ✅ | ⚠️ | ❌ |
| Composable queries | ✅ | ❌ | ⚠️ |
| Changeset validations | ✅ | ❌ | ⚠️ |
| Type-safe preload | ✅ | ❌ | ❌ |
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
│ (validation)│                       │ (postgres)  │
└─────────────┘                       └─────────────┘
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

**Requirements:** Nim >= 2.0.0, PostgreSQL >= 12, `db_connector` (installed automatically)

### 1. Define a Repo

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
```

---

## Testing

```bash
# Create test database
PGPASSWORD='pas+123' psql -U postgres -c "CREATE DATABASE necto_test;"

# Run tests
nimble test
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
| **0.3.0** | Advanced changeset, constraints, aggregates |
| **0.4.0** | Performance: prepared statements, batch insert, pool metrics |
| **1.0.0** | Async support, read replicas, production ready |

---

## License

MIT License — see [LICENSE](LICENSE).

---

*Built with ❤️ by the Nim community. Inspired by Ecto and Avram.*
