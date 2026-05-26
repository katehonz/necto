# Necto 🍯

> **PostgreSQL-first ORM за Nim 2.x**, вдъхновен от [Ecto](https://hexdocs.pm/ecto/Ecto.html) (Elixir) и [Avram](https://github.com/luckyframework/avram) (Crystal).

```nim
import necto

# Композируема, type-safe заявка
let users = repo.all(
  Query.from(User)
    .where("age >= ?", 18)
    .order_by("name", Asc)
    .preload(:posts)
)

# Changeset-driven писане
let cs = User.signup(%{"name": "Ivan", "email": "ivan@test.com"})
if cs.isValid:
  let user = repo.insert!(cs)
```

---

## Защо Necto?

Crystal общността създаде **Avram** — Ecto-подобен ORM, който я направи продуктивна за уеб разработка години по-рано. Nim общността заслужава същото ниво на абстракция.

| Функция | Necto | Norm | ActiveRecord |
|---------|-------|------|--------------|
| Repository Pattern | ✅ | ⚠️ | ❌ |
| Композируеми заявки | ✅ | ❌ | ⚠️ |
| Changeset валидации | ✅ | ❌ | ⚠️ |
| Type-safe preload | ✅ | ❌ | ❌ |
| Lazy loading | ❌ *(нарочно)* | ✅ | ✅ |
| PostgreSQL arrays | ✅ | ❌ | ⚠️ |

**Necto не прави lazy loading.** Винаги знаеш кога и как се изпълняват заявките.

---

## Архитектура

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Schema    │────▶│   Query     │────▶│    Repo     │
│  (структура)│     │  (заявка)   │     │  (връзка)   │
└─────────────┘     └─────────────┘     └──────┬──────┘
       │                                       │
       ▼                                       ▼
┌─────────────┐                       ┌─────────────┐
│  Changeset  │◀──────────────────────│   Adapter   │
│ (валидация) │                       │  (postgres) │
└─────────────┘                       └─────────────┘
```

| Компонент | Отговорност | Аналог |
|-----------|-------------|--------|
| **Schema** | Дефинира таблици, полета, типове, релации | Ecto.Schema |
| **Query** | Композируем DSL за SELECT | Ecto.Query |
| **Changeset** | Cast, валидация, проследяване на промени | Ecto.Changeset |
| **Repo** | Връзка, пул, транзакции | Ecto.Repo |
| **Migration** | Версиониране на схемата | Ecto.Migration |

---

## Инсталация

```bash
nimble install necto
```

Или локално:

```bash
git clone https://github.com/nim-community/necto.git
cd necto
nimble develop
```

### Изисквания

- Nim >= 2.0.0
- PostgreSQL >= 12
- `db_connector` пакет (инсталира се автоматично)

---

## Бърз старт

### 1. Дефинирай Repo

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

### 2. Дефинирай Schema

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string {.not_null, unique.}
  field age: Option[int]
  timestamps

  changeset signup(params):
    this
      |> cast(params, @[name, email, age])
      |> validate_required(@[name, email])
      |> validate_format(email, re".+@.+")
      |> unique_constraint(email)
```

### 3. Чети с Query

```nim
# Всички потребители
let all = repo.all(Query.from(User))

# Филтриране и сортиране
let adults = repo.all(
  Query.from(User)
    .where("age >= ?", 18)
    .order_by("name", Asc)
    .limit(10)
)

# Един резултат
let maybe = repo.one(Query.from(User).where("email = ?", "ivan@test.com"))

# Брой
let count = repo.count(Query.from(User).where("active = ?", true))
```

### 4. Пиши с Changeset

```nim
# INSERT
let cs = User.signup(%{"name": "Ivan", "email": "ivan@test.com", "age": "30"})
if cs.isValid:
  let user = repo.insert!(cs)
  echo "Created user: ", user.id
else:
  echo "Errors: ", cs.errors

# UPDATE
var cs = newChangeset(user, %{"name": "Ivan Petrov"})
cs = cs.cast(@["name"])
      .validate_required(@["name"])
let updated = repo.update!(cs)

# DELETE
repo.delete!(user)
```

### 5. Транзакции

```nim
repo.transaction proc() =
  let user = repo.insert!(User.signup(params))
  let post = repo.insert!(Post.changeset(%{
    "title": "Hello",
    "author_id": $user.id
  }))
  # Ако има изключение — автоматичен ROLLBACK
```

### 6. Асоциации и Preload

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  belongs_to author: User
  has_many comments: Comment
  timestamps

# Зарежда постове + автори (2 заявки, N+1 безопасно)
let posts = repo.all(
  Query.from(Post).preload(:author)
)

# Зарежда постове + филтрирани коментари
let posts = repo.all(
  Query.from(Post).preload(:comments)
)
```

---

## Миграции

### Създаване

```bash
nimble necto.gen.migration CreateUsers
```

### Писане

```nim
# migrations/m20260526120000_create_users.nim
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

### Регистрация

Създай `migrations.nim` в корена:

```nim
# migrations.nim
include migrations/m20260526120000_create_users
include migrations/m20260526130000_create_posts
```

### Изпълнение

```bash
# Прилага всички pending миграции
nimble necto.migrate

# Прилага последните 2
nimble necto.migrate --step 2

# Rollback на последната
nimble necto.rollback

# Статус
nimble necto.migrate_status
```

---

## Тестване

Проектът използва локален PostgreSQL:

```bash
# Създай тестова база
PGPASSWORD='pas+123' psql -U postgres -c "CREATE DATABASE necto_test;"

# Стартирай тестовете
nimble test
```

---

## Roadmap

| Версия | Цел |
|--------|-----|
| **0.1.0** | ✅ Скелет, schema, repo, adapter, миграции |
| **0.2.0** | 🔥 Type-safe query DSL, bound parameters, transaction context, preload |
| **0.3.0** | Advanced changeset, constraints, aggregates |
| **0.4.0** | Performance: prepared statements, batch insert, pool metrics |
| **1.0.0** | Async support, read replicas, production ready |

Пълният план: [PLAN.md](./PLAN.md)

---

## Лиценз

MIT License — виж [LICENSE](LICENSE).

---

*Създадено с ❤️ от Nim общността. Вдъхновено от Ecto и Avram.*
