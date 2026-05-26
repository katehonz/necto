# Necto — ORM за Nim, вдъхновен от Ecto (Elixir) и Avram (Crystal)

> **Цел:** Да донесем на Nim общността модерна, type-safe и композируема абстракция за работа с релационни бази данни, която се учи от най-добрите практики на Ecto и Avram.

## Защо Necto?

Crystal общността мигрира към Avram (Ecto-подобен ORM) и спечели години разработка. Nim общността все още няма еквивалентен инструмент, който съчетава:

- **Разделение на отговорностите** — Schema, Query, Changeset и Repo са отделни модули.
- **Type-safe заявки** — грешките в заявките се хващат по време на компилация, където е възможно.
- **Композируеми заявки** — можеш да вадиш части от заявки в отделни функции и да ги комбинираш.
- **Явни асоциации** — няма скрито "lazy loading". Винаги знаеш кога и как се зареждат релациите.
- **Мощен Changeset** — валидациите, cast-ването и проверката на ограниченията (constraints) са централизирани.

## Архитектура (4+1 компонента)

| Компонент | Отговорност | Ecto аналог | Avram аналог |
|-----------|-------------|-------------|--------------|
| `Repo` | Връзка с БД, пул от конекции, транзакции | `Ecto.Repo` | `Avram::Database` |
| `Schema` | Дефиниция на таблици, полета, типове, релации | `Ecto.Schema` | `Avram::Model` |
| `Query` | Композируем DSL за SELECT/UPDATE/DELETE | `Ecto.Query` | `Avram::Queryable` |
| `Changeset` | Cast, валидация, проследяване на промени | `Ecto.Changeset` | `Avram::SaveOperation` |
| `Migration` | Версиониране на схемата на БД | `Ecto.Migration` | `Avram::Migrator` |

## Бърз старт (визия)

```nim
import necto

# 1. Дефинираме Repo
necto_repo AppRepo:
  adapter necto.PostgresAdapter
  host "localhost"
  user "postgres"
  password "pas+123"
  database "my_app"

# 2. Дефинираме Schema
necto_schema User:
  table "users"
  field name: string
  field email: string
  field age: int
  timestamps                    # created_at, updated_at

  changeset signup(params: Table[string, string]):
    this
      |> cast(params, @["name", "email", "age"])
      |> validate_required(@["name", "email"])
      |> validate_format(:email, r".+@.+")
      |> validate_inclusion(:age, 18..100)
      |> unique_constraint(:email)

necto_schema Post:
  table "posts"
  field title: string
  field body: string
  belongs_to author: User
  timestamps

# 3. Заявки (композируеми)
let adults = AppRepo.all(
  Query.from(User)
    .where(_.age >= 18)
    .order_by(_.name.asc)
    .limit(10)
)

# 4. Preload на асоциации
let postsWithAuthors = AppRepo.all(
  Query.from(Post)
    .preload(:author)
)

# 5. Писане чрез Changeset
let ch = User.signup(params)
if ch.is_valid:
  let user = AppRepo.insert!(ch)
else:
  echo ch.errors

# 6. Транзакции
AppRepo.transaction do:
  let user = AppRepo.insert!(User.signup(params))
  let post = AppRepo.insert!(Post.changeset(%{"title": "Hello", "body": "World", "author_id": $user.id}))
```

## Миграции

```nim
# migrations/20260526120000_create_users.nim
necto_migration CreateUsers, "20260526120000":
  def up:
    create table(:users) do |t|
      t.primary_key :id, :bigserial
      t.string :name, null: false
      t.string :email, null: false, unique: true
      t.integer :age
      t.timestamps
    end

  def down:
    drop table(:users)
```

Стартиране:
```bash
nimble necto.migrate   # прилага миграциите
nimble necto.rollback  # отменя последната
nimble necto.gen.migration CreatePosts  # генерира нова миграция
```

## Инсталация

Добави в `myproject.nimble`:
```
requires "necto >= 0.1.0"
```

Или клонирай репото локално:
```bash
git clone https://github.com/nim-community/necto.git
cd necto
nimble develop
```

## Тестване

Проектът използва локален PostgreSQL:
- host: `localhost`
- user: `postgres`
- password: `pas+123`
- database: `necto_test`

```bash
nimble test
```

## Roadmap

Виж [PLAN.md](./PLAN.md) за пълната архитектура и фази на разработка.

## Лиценз

MIT License — виж [LICENSE](LICENSE).
