# Necto — Архитектурен план

> Версия: 0.1.0  
> Дата: 2026-05-26  
> Цел: PostgreSQL-first ORM за Nim 2.x, вдъхновен от Ecto (Elixir) и Avram (Crystal).

---

## 1. Философия

Necto не е "ActiveRecord" клонинг. Следваме **Repository Pattern** с ясно разделение:

- **Schema** — *какво* представляват данните (структура, типове, релации).
- **Query** — *как* четем данните (композируем DSL).
- **Changeset** — *как* променяме данните (cast, валидация, constraints).
- **Repo** — *къде* живеят данните (връзка, транзакции, адаптер).

За разлика от съществуващия `norm`, Necto ще бъде:
- **Macro-heavy** — генерираме type-safe методи за всяка колона и асоциация по време на компилация.
- **Query-first** — заявките са първокласни обекти, не просто натрупани низове.
- **Changeset-driven writes** — вмъкване/актуализация минават през changeset, а не директно през обект.
- **No lazy loading** — асоциациите се зареждат само чрез `preload`, както в Ecto.

---

## 2. Структура на проекта

```
necto/
├── necto.nimble
├── README.md
├── PLAN.md
├── src/
│   ├── necto.nim                    # Публичен API — import necto
│   └── necto/
│       ├── repo.nim                 # Repo макро и runtime
│       ├── schema.nim               # Schema/Model макроси
│       ├── changeset.nim            # Changeset тип и валидации
│       ├── query.nim                # Query DSL и структура
│       ├── query_builder.nim        # SQL генератор
│       ├── type_system.nim          # Cast/Load/Dump, custom types
│       ├── associations.nim         # HasMany, BelongsTo, HasOne
│       ├── preloader.nim            # Preload логика
│       ├── migration.nim            # Миграционен DSL
│       ├── migrator.nim             # Runner и версиониране
│       ├── adapters/
│       │   ├── base.nim             # Адаптер интерфейс
│       │   └── postgres.nim         # PostgreSQL имплементация
│       └── errors.nim               # Изключения (NotFoundError, RollbackError...)
├── tests/
│   ├── support/
│   │   ├── test_repo.nim            # Тестов Repo
│   │   └── test_schemas.nim         # Тестови модели
│   ├── t_repo.nim
│   ├── t_schema.nim
│   ├── t_query.nim
│   ├── t_changeset.nim
│   ├── t_associations.nim
│   └── t_migrations.nim
└── examples/
    └── friends/                     # Като Ecto examples/friends
        ├── src/friends.nim
        └── migrations/
```

---

## 3. Технологичен стек

| Компонент | Избор | Алтернатива | Забележка |
|-----------|-------|-------------|-----------|
| Nim версия | **2.2.x** | — | Използваме `strictFuncs`, `views` където е уместно. |
| PostgreSQL драйвер | **ndb/postgres** или **db_postgres** | asyncpg | За MVP синхронен достъп е по-прост за дебъгване. |
| Connection pool | **Вграден в Necto** | Външен пакет | Nim няма стандартен пул; ще ползваме `Deque` + `locks`. |
| SQL placeholders | **$1, $2 …** (PostgreSQL) | ? | PostgreSQL-specific за по-чист код. |
| Макро система | **Nim macros/stdlib** | — | Ще комбинираме `macro`, `typeinfo`, `fieldPairs`. |

---

## 4. Фази на разработка

### Фаза 0: Скелет и инфраструктура
- [ ] `necto.nimble` със зависимости.
- [ ] CI конфигурация (GitHub Actions) с PostgreSQL service.
- [ ] Тестова база данни `necto_test` (host: localhost, user: postgres, password: pas+123).
- [ ] Базов `errors.nim`.

### Фаза 1: Repo + PostgreSQL Адаптер
**Цел:** Можем да се свързваме с БД и да изпълняваме raw SQL.

- [ ] `necto/adapters/base.nim` — интерфейс/концепт:
  ```nim
  type Adapter* = concept a
    a.connect() is Connection
    a.query(conn, sql, args) is seq[Row]
    a.exec(conn, sql, args)
    a.transaction(conn, body)
  ```
- [ ] `necto/adapters/postgres.nim` — обвивка около `db_postgres`:
  - `PgAdapter` с конфигурация (host, port, user, password, database, pool_size).
  - Connection pool с `lock` и `Deque[DbConn]`.
  - `checkout()` / `checkin()`.
- [ ] `necto/repo.nim` — `necto_repo` макро:
  ```nim
  necto_repo AppRepo:
    adapter PgAdapter
    host "localhost"
    database "my_app"
    pool_size 10
  ```
  Генерира модул `AppRepo` с:
  - `proc all*(sql: SqlQuery, args: varargs[string, `$`]): seq[Row]`
  - `proc one*(...): Row`
  - `proc transaction*(body: proc())`
  - `proc insert*(sql, args)` и т.н.

### Фаза 2: Schema (Model) дефиниция
**Цел:** Дефинираме модели с полета, типове и метаданни.

- [ ] `necto/schema.nim` — `necto_schema` макро:
  ```nim
  necto_schema User:
    table "users"
    field id: int64 {primary_key, auto_increment}
    field name: string {null: false}
    field email: string {null: false, unique: true}
    field age: int
    field inserted_at: DateTime
    field updated_at: DateTime
  ```
  Генерира:
  - `User` обект (`ref object` или `object`) с полета.
  - `UserMetadata` константа — информация за таблица, колони, типове.
  - `User.__schema__()` reflection функции.
  - `User.__changeset__()` — map от поле -> тип.
- [ ] Поддръжка на:
  - Custom primary keys (`primary_key custom_id: string`).
  - `timestamps` макро — добавя `inserted_at`, `updated_at`.
  - `virtual` полета — не се записват в БД.
  - `embeds_one` / `embeds_many` (по-късно, чрез JSONB).

### Фаза 3: Type System
**Цел:** Cast между Nim типове и PostgreSQL типове.

- [ ] `necto/type_system.nim` — `NectoType` протокол/концепт:
  ```nim
  type NectoType*[T] = concept t
    t.cast(value: string): Result[T, string]
    t.load(db_value: string): T
    t.dump(value: T): string
    t.db_type(): string          # "varchar", "int8", "timestamp" ...
  ```
- [ ] Built-in типове:
  - `string` → `text`/`varchar`
  - `int`, `int64`, `float` → `int4`, `int8`, `float8`
  - `bool` → `boolean`
  - `DateTime` → `timestamp with time zone`
  - `JsonNode` → `jsonb`
  - `seq[T]` → масиви (PostgreSQL arrays)
- [ ] Custom types — потребителят може да дефинира:
  ```nim
  type Status* = enum Active, Inactive
  necto_enum(Status)  # генерира NectoType имплементация
  ```

### Фаза 4: Query Builder
**Цел:** Type-safe, композируем DSL за заявки.

- [ ] `necto/query.nim` — `Query[T]` структура:
  ```nim
  type Query*[T] = object
    select_fields: seq[string]
    wheres: seq[WhereClause]
    joins: seq[JoinClause]
    orders: seq[OrderClause]
    limit_val: Option[int]
    offset_val: Option[int]
    preload_assocs: seq[string]
  ```
- [ ] DSL:
  ```nim
  Query.from(User)
    .where(_.age >= 18 and _.name == "Ivan")
    .order_by(_.age.desc)
    .limit(10)
    .offset(20)
    .select(_.id, _.name)
  ```
- [ ] **Техническо предизвикателство:** Nim макросите не позволяват точно същия синтаксис като Crystal (`_.age >= 18`).
    - **Решение:** Използваме `dot` макро или `it` шаблон:
    ```nim
    Query.from(User).where(it.age >= 18).where(it.name == "Ivan")
    ```
    Или пък:
    ```nim
    Query.from(User).where(q => q.age >= 18 and q.name == "Ivan")
    ```
- [ ] SQL генератор в `query_builder.nim`:
  - Произвежда `SELECT ... FROM ... WHERE ...` с `$N` placeholders.
  - Поддържа `AND`, `OR`, `IN`, `IS NULL`, `LIKE`, `ILIKE`.
  - Поддържа `JOIN` (inner, left, right).
- [ ] Repo integration:
  ```nim
  AppRepo.all(query)  # -> seq[User]
  AppRepo.one(query)  # -> Option[User]
  AppRepo.count(query) # -> int64
  ```

### Фаза 5: Changeset
**Цел:** Всяка промяна на данни минава през валидация и cast.

- [ ] `necto/changeset.nim` — `Changeset[T]` структура:
  ```nim
  type Changeset*[T] = object
    data*: T                    # оригиналният обект (или празен)
    params*: Table[string, string] # raw вход
    changes*: Table[string, string] # само променените полета
    errors*: Table[string, seq[string]]
    valid*: bool
    action*: Action            # Create | Update | Delete
  ```
- [ ] `cast` — филтрира позволени полета и конвертира типове:
  ```nim
  proc cast*[T](cs: Changeset[T], params: Table[string, string], permitted: openArray[string]): Changeset[T]
  ```
- [ ] Вградени валидации:
  - `validate_required(fields)`
  - `validate_format(field, regex)`
  - `validate_inclusion(field, range|seq)`
  - `validate_length(field, min, max)`
  - `validate_number(field, greater_than, less_than)`
  - `validate_confirmation(field)` — за пароли.
- [ ] Constraints (проверяват се от БД, грешките се мапват обратно):
  - `unique_constraint(field)`
  - `foreign_key_constraint(field)`
- [ ] Changeset дефиниран в самия schema:
  ```nim
  necto_schema User:
    ...
    changeset signup(params):
      this
        |> cast(params, @["name", "email"])
        |> validate_required(@["name", "email"])
        |> validate_format(:email, re".+@.+")
  ```
- [ ] Repo write API:
  ```nim
  AppRepo.insert!(changeset)  # -> T или хвърля ValidationError
  AppRepo.update!(changeset)  # -> T
  AppRepo.delete!(changeset)  # -> T
  AppRepo.insert(changeset)   # -> Result[T, Changeset[T]]
  ```

### Фаза 6: Associations
**Цел:** Релации между модели без lazy loading.

- [ ] `necto/associations.nim` — макроси:
  ```nim
  necto_schema Post:
    belongs_to author: User        # добавя `author_id: int64`
    has_many comments: Comment     # няма колона в БД, само метаданни
  ```
- [ ] Preload:
  ```nim
  AppRepo.all(
    Query.from(Post).preload(:author)
  )
  # Изпълнява 2 заявки и асемблира обектите.
  ```
  ```nim
  AppRepo.all(
    Query.from(Post).preload(:comments, Query.from(Comment).where(it.approved == true))
  )
  ```
- [ ] `Ecto.assoc` еквивалент:
  ```nim
  let comments = AppRepo.all(necto.assoc(post, :comments))
  ```
- [ ] `build_assoc`:
  ```nim
  let comment = necto.build_assoc(post, :comments, %{"body": "Nice!"})
  ```

### Фаза 7: Migrations
**Цел:** Версиониране на схемата.

- [ ] `necto/migration.nim` — DSL:
  ```nim
  necto_migration CreateUsers, "20260526120000":
    def up:
      create table(:users) do |t|
        t.primary_key :id, :bigserial
        t.string :name, null: false
        t.string :email, null: false
        t.index :email, unique: true
        t.timestamps
      end

    def down:
      drop table(:users)
  ```
- [ ] `necto/migrator.nim` — runner:
  - Проверява таблица `necto_schema_migrations`.
  - Изпълнява pending миграции в транзакция.
  - Поддържа `up`, `down`, `redo`, `status`.
- [ ] Nimble tasks:
  ```bash
  nimble necto.migrate
  nimble necto.rollback
  nimble necto.gen.migration CreatePosts
  ```

### Фаза 8: Advanced Query Features
- [ ] `select` с агрегати: `count`, `sum`, `avg`, `min`, `max`.
- [ ] `group_by` и `having`.
- [ ] `distinct` и `distinct_on` (PostgreSQL).
- [ ] `lock` (`FOR UPDATE`).
- [ ] Subqueries: `where(it.id.in(Query.from(...)))`.
- [ ] Raw SQL fragments: `where(fragment("lower(?) = ?", name, "ivan"))`.
- [ ] `union` / `intersect` / `except`.

### Фаза 9: Async/Pool/Performance
- [ ] Опционална async поддръжка чрез `asyncpg`.
- [ ] По-интелигентен connection pool (min/max, timeout, health check).
- [ ] Prepared statement cache.
- [ ] Batch inserts (`insert_all`).

### Фаза 10: Multi-database, Read Replicas
- [ ] `Repo.put_dynamic_repo()` подобно на Ecto.
- [ ] Read/Write split конфигурация.

---

## 5. Специфични Nim предизвикателства и решения

### 5.1 Макро система vs. Crystal/Elixir

| Ecto/Avram | Nim решение |
|------------|-------------|
| `schema "users" do ... end` | `necto_schema User: ...` — `macro` трансформира тялото в `type` + метаданни. |
| `field :name, :string` | `field name: string` — използваме Nim типове директно. |
| Pipe оператор `\|>` | Nim има вграден `\|>` за прокарване; използваме го за changesets. |
| `from u in User, where: u.age > 18` | `Query.from(User).where(it.age > 18)` — `it` е специален идентификатор, който макрото разпознава. |
| `^min` за интерполация | Не е нужно — Nim има стандартни променливи; просто подаваме стойностите като params. |

### 5.2 Type Reflection

Nim предоставя:
- `fieldPairs` — обхождане на полетата на обект по време на компилация.
- `hasCustomPragma` / `getCustomPragmaVal` — за метаданни върху полета.
- `typeinfo` — runtime reflection, по-бавен.

Ще ползваме **compile-time reflection** за генериране на query criteria, changeset атрибути и migration колони.

### 5.3 Грешки и Exception Safety

- Ecto връща `{:ok, _} / {:error, _}` tuples. Nim няма вграден Result тип в stdlib, но можем да използваме `Option` + exceptions или външен `result` пакет.
- **Решение:** Публичният API ще предоставя два варианта:
  ```nim
  proc insert*[T](repo: Repo, cs: Changeset[T]): T  # хвърля ValidationError
  proc insert*[T](repo: Repo, cs: Changeset[T]): Result[T, Changeset[T]]  # връща грешката
  ```
  За простота в MVP-то започваме с exceptions, после добавяме `Result` варианти.

---

## 6. База данни за разработка

```yaml
# config/test.yml (или .env)
NECTO_DB_HOST: localhost
NECTO_DB_PORT: 5432
NECTO_DB_USER: postgres
NECTO_DB_PASS: pas+123
NECTO_DB_NAME: necto_test
```

Всяка тестова функция се очаква да работи в транзакция, която се rollback-ва след теста (setup/teardown).

---

## 7. Критерии за успех (MVP)

За да кажем, че Necto е готов за първи release, трябва да работи:

1. Свързване с PostgreSQL чрез Repo.
2. Дефиниране на Schema с полета, primary key, timestamps.
3. CRUD през Changeset (cast + validate_required + insert/update/delete).
4. Прости заявки: `where`, `order_by`, `limit`, `offset`, `select`.
5. `preload` на `belongs_to` и `has_many`.
6. Миграции с `create table`, `add`, `drop`.
7. Поне 80% code coverage на core модули.

---

## 8. Вдъхновение и благодарности

- [Ecto](https://github.com/elixir-ecto/ecto) — José Valim и екипът на Elixir.
- [Avram](https://github.com/luckyframework/avram) — Lucky Framework и Crystal общността.
- [Norm](https://github.com/moigagoo/norm) — съществуващ ORM за Nim, от който ще се учим какво да избегнем и какво да подобрим.

---

*Планът е жив документ — ще се актуализира с всяка нова фаза.*
