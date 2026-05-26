# Necto — Архитектурен план v2.0

> Версия: 0.2.0  
> Дата: 2026-05-26  
> Цел: PostgreSQL-first ORM за Nim 2.x, вдъхновен от Ecto (Elixir) и Avram (Crystal).  
> Мото: *Crystal общността направи Avram. Nim заслужава нещо още по-добро.*

---

## 1. Философия и принципи

Necto не е ActiveRecord. Следваме **Repository Pattern** със стриктно разделение:

- **Schema** — *какво* представляват данните (структура, типове, релации, виртуални полета).
- **Query** — *как* четем данните (композируем, immutable, type-safe DSL).
- **Changeset** — *как* променяме данните (cast, валидация, constraints, dirty tracking).
- **Repo** — *къде* живеят данните (връзка, пул, транзакции, адаптер).

### Защо не ActiveRecord?

| ActiveRecord проблем | Necto решение |
|---------------------|---------------|
| Скрито lazy loading (N+1) | **Явен `preload`** — винаги знаеш кога се зареждат релации |
| Моделът знае за БД (`.save`) | **Repo е единственият gateway** — моделът е чиста структура |
| SQL injection през string interpolation | **Parameterized queries** — `$1, $2` placeholders навсякъде |
| Runtime грешки в заявки | **Compile-time проверка** на полета и типове където е възможно |

---

## 2. Структура на проекта

```
necto/
├── necto.nimble
├── README.md
├── PLAN.md
├── AGENTS.md
├── src/
│   ├── necto.nim                    # Публичен API — `import necto`
│   └── necto/
│       ├── repo.nim                 # Repo макро, connection context, transaction scope
│       ├── schema.nim               # `necto_schema` макро, reflection, row loader
│       ├── changeset.nim            # Changeset тип, cast, валидации, constraints
│       ├── query.nim                # Query AST структура
│       ├── query_builder.nim        # SQL генератор с parameter binding
│       ├── query_dsl.nim            # Type-safe макроси: `where`, `select`, `order_by`
│       ├── type_system.nim          # Cast/Load/Dump, custom types, enums
│       ├── associations.nim         # HasMany, BelongsTo, HasOne метаданни
│       ├── preloader.nim            # Batch preload (N+1 safe), typedesc dispatch
│       ├── migration.nim            # Migration DSL + SQL генератори
│       ├── migrator.nim             # Runner, версиониране, CLI hooks
│       ├── adapters/
│       │   ├── base.nim             # Adapter интерфейс
│       │   └── postgres.nim         # PostgreSQL имплементация + пул
│       └── errors.nim               # Изключения йерархия
├── tests/
│   ├── support/
│   │   ├── test_repo.nim            # Тестов Repo конфиг
│   │   └── test_schemas.nim         # Тестови модели (User, Post, Comment)
│   ├── t_repo.nim                   # Connection, transaction, pool тестове
│   ├── t_schema.nim                 # Schema макро + reflection тестове
│   ├── t_query.nim                  # Query DSL + SQL генерация
│   ├── t_changeset.nim              # Cast, валидации, грешки
│   ├── t_associations.nim           # BelongsTo, HasMany, preload
│   ├── t_migrations.nim             # Миграции up/down
│   └── t_integration.nim            # Пълен интеграционен тест (CRUD + query + preload)
└── examples/
    └── friends/                     # Пълен пример със seed + CRUD + query
        ├── friends.nim
        └── migrations/
```

---

## 3. Технологичен стек

| Компонент | Избор | Забележка |
|-----------|-------|-----------|
| Nim | **2.2.x** | ORC, `strictFuncs`, `views` |
| PostgreSQL драйвер | **db_connector/db_postgres** | Синхронен, стабилен, част от Nim ecosystem |
| Connection pool | **Вграден** (`Deque` + `Lock`) | Nim няма стандартен пул |
| SQL placeholders | **$1, $2, …** | PostgreSQL native |
| Macros | **Nim macros/stdlib** | `macro`, `typedesc`, `fieldPairs`, `hasCustomPragma` |
| Test runner | **unittest** | Стандартен Nim модул |

---

## 4. Критични Nim предизвикателства и решения

### 4.1 Type-safe query DSL без `it` захващане (като Crystal/Elixir)

**Проблем:** Nim няма `it` макро като Crystal, нито `^` интерполация като Ecto.
**Решение:** Използваме **static string макро** с compile-time проверка:

```nim
# Вместо: Query.from(User).where(it.age >= 18)  # невъзможно в Nim
# Ползваме:
Query.from(User).where("age >= ?", 18)          # runtime params
# или (в бъдеще):
Query.from(User).whereIt(age >= 18)              # макро проверява `age` поле
```

За **`whereIt`** макрото:
- Извлича идентификаторите от AST (`age`, `name`).
- Проверява срещу `SchemaMeta.fields` по време на компилация (чрез `static` блок).
- Генерира `where("age >= ?", "18")` с правилен тип conversion.

### 4.2 Connection Context в транзакции

**Проблем:** `repo.transaction(body)` не може да предаде `conn` на `body`, защото `body` е `proc()` без параметри.
**Решение:** **Thread-local connection context**:

```nim
var threadLocalConn {.threadvar.}: Connection

proc getConn(repo: Repo): Connection =
  if threadLocalConn != nil:
    return threadLocalConn
  return repo.adapter.connect()

proc transaction(repo: Repo, body: proc()) =
  let conn = repo.adapter.connect()
  threadLocalConn = conn
  try:
    repo.adapter.beginTransaction(conn)
    body()
    repo.adapter.commitTransaction(conn)
  except:
    repo.adapter.rollbackTransaction(conn)
    raise
  finally:
    threadLocalConn = nil
    repo.adapter.disconnect(conn)
```

Така `repo.insert(cs)` вътре в `transaction` автоматично ползва същата връзка.

### 4.3 Preload с typedesc dispatch

**Проблем:** `preloadBelongsTo` е generic, но трябва да извика `load(row, Child)` за различни `Child` типове.
**Решение:** `load` е вече overloaded по `typedesc`. В `preload` използваме `macro` за генериране на `when` разклонения за всеки възможен Child тип, или пазим `proc(row: DbRow): RootObj` callback в `AssocMeta`.

По-чисто решение (като Ecto): `preload` е **template**, който резолвира `load` по време на компилация:

```nim
template preload*[T, A](repo: Repo, records: var seq[T], assoc: typedesc[A]) =
  when A is User:
    preloadBelongsTo[T, User](repo, records, assocMeta, UserSchema)
  elif A is Post:
    preloadBelongsTo[T, Post](repo, records, assocMeta, PostSchema)
```

### 4.4 Parameter binding (SQL Injection защита)

**Проблем:** Текущият `Query.toSql` слага стойностите директно в SQL низа.
**Решение:** Query натрупва **`(sql_fragment, params)`** двойки:

```nim
type BoundQuery* = object
  sql*: string
  args*: seq[string]

proc toBoundQuery*[T](q: Query[T]): BoundQuery =
  # Генерира SQL с $1, $2 placeholders + seq от стойности
```

Repo методите (`all`, `one`, `count`) винаги ползват `adapter.query(conn, boundQuery.sql, boundQuery.args)`.

### 4.5 Changeset type casting

**Проблем:** `castFields` копира string стойности без conversion.
**Решение:** Schema-aware cast чрез `SchemaMeta`:

```nim
proc castFields*[T](cs: Changeset[T], permitted: openArray[string]): Changeset[T] =
  let meta = schemaMeta(T)
  for field in permitted:
    if cs.params.hasKey(field):
      let fmeta = meta.fieldByName(field)
      let rawVal = cs.params[field]
      try:
        let casted = castValue(rawVal, fmeta.nimType)  # dispatch по тип
        cs.changes[field] = rawVal  # или сериализирана стойност
      except ValueError:
        cs.addError(field, "is invalid")
```

---

## 5. Фази на разработка (приоритизирани)

### ✅ Фаза 0: Скелет (ГОТОВО)
- [x] `necto.nimble`, модули, errors, adapter interface
- [x] PostgreSQL адаптер с пул
- [x] `necto_schema` макро (тип, meta, constructor, loader)
- [x] `necto_repo` макро
- [x] `necto_migration` макро + migrator
- [x] CLI tasks: migrate, rollback, status, gen_migration

### 🔥 Фаза 1: Core стабилност (КРИТИЧНО)
- [x] **Connection context** — thread-local conn за транзакции
- [x] **Bound queries** — всички заявки с `$N` placeholders + args
- [x] **Schema-aware cast** — Changeset прави реално type conversion
- [x] **Основни тестове** — поне 80% покритие на repo, query, changeset
- [x] **Integration test** — пълен CRUD цикъл върху реална PostgreSQL

### 🔥 Фаза 2: Query DSL (КРИТИЧНО)
- [x] `where(field, op, value)` с правилно parameter binding
- [x] `whereIt` макро — compile-time field checking
- [x] `select`, `order_by`, `limit`, `offset`, `distinct`
- [x] `join` — inner/left/right с type-safe колони
- [x] `count`, `sum`, `avg` агрегати
- [x] `group_by`, `having`
- [x] Subqueries: `where("id IN ?", subquery)`
- [x] Raw fragments: `where(fragment("lower(?) = ?", name, "ivan"))`

### 🔥 Фаза 3: Асоциации и Preload (КРИТИЧНО)
- [ ] `belongs_to` — batch preload (2 заявки)
- [ ] `has_many` — batch preload + filter subquery
- [ ] `has_one` — batch preload
- [ ] `preload` в Query: `Query.from(Post).preload(:author)`
- [ ] `preload` в Repo: `repo.preload(posts, :author)`
- [ ] `build_assoc` / `assoc` helper-и

### Фаза 4: Advanced Changeset
- [ ] `validate_confirmation`, `validate_exclusion`, `validate_subset`
- [x] `unique_constraint` с DB проверка (лови `unique_violation`)
- [x] `foreign_key_constraint` с DB проверка
- [ ] `put_change`, `force_change`, `delete_change`
- [x] `apply_changes` — връща обект без запис в БД

### Фаза 5: Advanced Migrations
- [x] `rename_table`, `rename_column`
- [x] `add_index`, `drop_index` (concurrent)
- [x] `add_reference`, `remove_reference`
- [x] `execute` — raw SQL в миграция
- [ ] Migration rollback с `up`/`down` checksum валидация

### Фаза 6: Performance и Production readiness
- [ ] Prepared statement cache (per connection)
- [ ] Batch insert: `insert_all(schemas, entries)`
- [ ] Connection pool metrics (wait time, active conns)
- [ ] Query timeout и slow query log
- [ ] Read replica support: `repo.read()` vs `repo.write()`

### Фаза 7: Async (бъдеще)
- [ ] Async adapter върху `asyncpg` или `pgasync`
- [ ] `async` варианти на `all`, `one`, `insert`, `update`

---

## 6. API Design (целево)

### Schema

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string {.not_null, unique.}
  field age: Option[int]
  field meta: JsonNode
  timestamps                         # created_at, updated_at

  changeset signup(params):
    this
      |> cast(params, @[name, email, age])
      |> validate_required(@[name, email])
      |> validate_format(email, re".+@.+")
      |> validate_inclusion(age, 18..120)
      |> unique_constraint(email)
```

### Query

```nim
let adults = repo.all(
  Query.from(User)
    .where("age >= ?", 18)
    .where("name ILIKE ?", "Ivan%")
    .order_by("name", Asc)
    .limit(10)
    .preload(:posts)
)

let count = repo.count(Query.from(User).where("active = ?", true))
```

### Changeset + Write

```nim
let cs = User.signup(params)
if cs.isValid:
  let user = repo.insert!(cs)
else:
  echo cs.errors

# Update
var cs = user |> change(%{"name": "New Name"})
              |> validate_required(@["name"])
repo.update!(cs)
```

### Transaction

```nim
repo.transaction proc() =
  let user = repo.insert!(User.signup(params))
  let post = repo.insert!(Post.changeset(%{"title": "Hello", "author_id": $user.id}))
  # Ако има грешка — автоматичен rollback
```

---

## 7. База данни за разработка и тестове

```bash
# PostgreSQL (вече създадена)
PGHOST=localhost
PGUSER=postgres
PGPASSWORD=pas+123
PGDATABASE=necto_test
PGPORT=5432
```

Всеки тест работи в транзакция с автоматичен rollback (setup/teardown pattern):

```nim
setup:
  repo.exec("BEGIN")
teardown:
  repo.exec("ROLLBACK")
```

---

## 8. Критерии за успех (v0.2.0 MVP)

1. **Компилира се** без warnings на Nim 2.2.x.
2. **Всички тестове минават** с реална PostgreSQL връзка.
3. **SQL Injection невъзможен** — никога не конкатенираме стойности в SQL.
4. **Transaction safety** — N операции в транзакция използват една връзка.
5. **N+1 елиминиран** — `preload` зарежда асоциациите в точно 2 заявки.
6. **Type-safe заявки** — грешни имена на полета се хващат на compile-time (чрез `whereIt`).
7. **Clean separation** — Schema не знае за Repo, Query не знае за Adapter.

---

## 9. Вдъхновение

- **[Ecto](https://github.com/elixir-ecto/ecto)** — José Valim. Златен стандарт за ORM дизайн.
- **[Avram](https://github.com/luckyframework/avram)** — Lucky Framework. Показа че Ecto-идеите работят в compiled език.
- **[Norm](https://github.com/moigagoo/norm)** — съществуващ Nim ORM. Доказа че Nim може да има ORM, но липсва Query DSL и Changeset.
- **[Diesel](https://diesel.rs/)** (Rust) — type-safe SQL. Мотивация за compile-time проверки.

---

*Планът е жив документ. Актуализира се с всяка нова фаза.*
