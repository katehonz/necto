# План: Necto да бие Ecto

## Мета

Ecto е златен стандарт с 10+ години production зрялост. Няма да го бием с "още един клон". Ще го бием като станем **най-добрият ORM за PostgreSQL в compile-to-native света** — с zero-cost абстракции, compile-time type safety и single-binary deployment, които Elixir никога няма да има.

## Философия

1. **Не копираме Ecto — надграждаме го** с неща, които са невъзможни в BEAM.
2. **PostgreSQL-first, не database-agnostic.** Ще сме най-добрият PostgreSQL ORM, не най-универсалният.
3. **Всяка нова функционалност = тест първо.**
4. **Zero breaking changes след 0.3.0.**

---

## Фаза 0: Спешни бъгфиксове (Седмица 0)

*Цел: Кодът да е стабилен преди да добавяме нови фичъри.*

| Задача | Файл | Описание | Трудност |
|--------|------|----------|----------|
| Fix `oneWithPreload` macro | `repo.nim:206` | `q2 = q2.limit(1)` вместо `q2.limit = 1` | Лесна |
| Fix HAVING SQL генерация | `query.nim:334-360` | Добави `Like/Ilike/In/IsNull/NotNull` в HAVING. Добави `conjunction` поле (AND/OR). | Средна |
| Fix `build_assoc` при множество асоциации | `associations.nim:37-55` | Търси по `assoc.name`, не само по `targetSchema` | Средна |
| Fix `count` с GROUP BY | `repo.nim:161` | `count` трябва да връща `seq[(group, count)]` при GROUP BY, не скалар | Средна |
| Изтрий binary файлове от git | — | `src/necto.out`, `src/necto/query.out`, `src/necto/migrator.out` + `.gitignore` | Лесна |
| Обнови `TYPE_GAP_ANALYSIS.md` | `docs/` | Всички "липсващи" типове вече са имплементирани — документът въвежда в заблуда | Лесна |

---

## Фаза 1: Ecto Parity — критични липси (Седмица 1–3)

*Цел: Всичко, без което production Nim ORM е непълноценен.*

### 1.1 `NectoMulti` — композируеми транзакции

Ecto.Multi е един от най-мощните патърни в Ecto. В Nim можем да го направим **по-добър** с compile-time проверки на операциите.

```nim
let multi = newMulti()
  .insert("user", userCs)
  .insert("profile", profileCs, dependsOn = @["user"])
  .update("account", accountCs)

repo.transactionMulti(multi)  # Всичко или нищо
```

**Предимство пред Ecto:** Compile-time проверка дали `dependsOn` операции съществуват в multi-то.

### 1.2 `many_to_many` асоциации

```nim
necto_schema User:
  many_to_many roles: Role through "user_roles"
```

Автоматична join таблица, preload през JOIN, `build_assoc` с двойно FK попълване.

### 1.3 Embedded schemas (`embeds_one`, `embeds_many`)

```nim
necto_schema User:
  field settings: JsonNode
  embeds_one profile: Profile  # stored as jsonb, но с changeset/validation
  embeds_many addresses: Address
```

Профилът е отделен Nim тип със свой changeset, но се пази в една колона (`jsonb`). Валидациите се run-ват nest-нато.

### 1.4 Savepoints / Nested Transactions

```nim
repo.transaction:
  repo.insert(userCs)
  repo.savepoint("sp1"):
    repo.insert(orderCs)
    repo.rollbackTo("sp1")  # Partial rollback
```

PostgreSQL `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` интеграция.

### 1.5 Manual `repo.rollback()`

```nim
repo.transaction:
  let user = repo.insert(userCs)
  if user.email.endsWith("@banned.com"):
    repo.rollback()  # Graceful abort без exception
```

### 1.6 Upserts (`on_conflict`)

```nim
repo.insert(userCs, onConflict = DoNothing)
repo.insert(userCs, onConflict = DoUpdate(@["email", "name"]))
```

`INSERT ... ON CONFLICT DO NOTHING/UPDATE` — PostgreSQL native.

### 1.7 `change` direction за миграции

```nim
necto_migration CreateUsers, "20260526120000":
  change:
    createTable "users", cols(...)
    # Rollback се infers автоматично: dropTable "users"
```

Авто-реверсивни операции: `createTable`↔`dropTable`, `addColumn`↔`dropColumn`, `addIndex`↔`dropIndex`.

---

## Фаза 2: Nim Superpowers — "Невъзможно в Ecto" (Седмица 3–6)

*Цел: Killer features, които са уникални за compile-to-native език с макроси. Това е където "бием" Ecto.*

### 2.1 Compile-time type-safe JSON paths за `JsonB[T]`

```nim
type UserSettings = object
  theme: string
  notifications: bool

# Това се проверява на compile time:
let q = Query.fromSchema(User)
  .whereJsonb("settings", "theme", Eq, "dark")   # ✅
  .whereJsonb("settings", "theem", Eq, "dark")  # ❌ Compile error: path "theem" not found in UserSettings
```

Nim макросите инспектират `UserSettings` и проверяват дали пътят съществува.

### 2.2 Zero-copy PostgreSQL array loading

В момента масивите се parse-ват от текстов `{a,b,c}` формат. Можем да parse-ваме директно от PostgreSQL wire protocol формат (binary) без междинен string allocation.

### 2.3 Integrated JSONB query operators

```nim
Query.fromSchema(User)
  .where("data", JsonContains, %*{"role": "admin"})     # @> operator
  .where("data", JsonContainedBy, %*{"name": "Ivan"})   # <@ operator
  .where("tags", JsonAny, "urgent")                       # ? operator
  .where("tags", JsonAll, @["urgent", "customer"])        # ?& operator
```

Native PostgreSQL JSONB оператори като първокласни query операции.

### 2.4 Compile-time query plan caching

```nim
# Това се изпълнява в compile-time:
const cachedQuery = compileQuery(Query.fromSchema(User).where("age", Gte, "18"))
# cachedQuery.sql е string constant — zero runtime overhead за SQL генерация
```

Вече имаме `compileQuery`, но можем да го разширим за **всички** статични заявки.

### 2.5 `Decimal` като fixed-point `int64`

```nim
type FixedDecimal*[Scale: static int] = distinct int64
# FixedDecimal[2] = 2 decimal places. 12345 = 123.45
```

Zero allocation, zero dependency на bignum библиотеки, по-бързо от Ecto's `Decimal`. За финанси `FixedDecimal[2]` е перфектен.

### ✅ 2.6 Static foreign key integrity check (ГОТОВО)

```nim
necto_schema Comment:
  belongs_to post: Post
  # Compile time: проверяваме дали Post има id: int64 (PK)
  # Грешка ако типът на FK не съвпада с PK типа
```

---

## Фаза 3: Production Ready — "По-добър от Norm за реални проекти" (Седмица 6–9)

### 3.1 Streaming (`repo.stream`)

```nim
for user in repo.stream(Query.fromSchema(User).where("active", Eq, "true")):
  process(user)  # Cursor-based, без seq[T] allocation
```

PostgreSQL cursor (`DECLARE ... CURSOR`) интеграция.

### 3.2 Soft deletes

```nim
necto_schema Post:
  field deleted_at: Option[DateTime]
  soft_delete

# Автоматично:
Query.fromSchema(Post)           # WHERE deleted_at IS NULL
Query.fromSchema(Post, withDeleted = true)  # всички
repo.delete(post)  # SET deleted_at = NOW() вместо DELETE
```

### 3.3 Transaction savepoints (вж. Фаза 1.4)

### 3.4 Prepared statement cache per-connection

В момента `PostgresAdapter` има prepared stmt cache, но не per-connection. Да се добави `PreparedStatementCache` per `PgConnection`.

### 3.5 Migration locking (`pg_advisory_lock`)

```nim
mig.migrate()  # Автоматично: SELECT pg_advisory_lock(12345)
```

Предотвратява race conditions при concurrent deployment.

### 3.6 Full-text search DSL

```nim
Query.fromSchema(Article)
  .whereTextSearch("content", "postgres & (tutorial | guide)")
  .orderByRank("content", "postgres & tutorial")
```

`tsvector`/`tsquery` helper-и като `to_tsvector`, `plainto_tsquery`, `websearch_to_tsquery`.

### ✅ 3.7 Subqueries и CTEs (ГОТОВО — CTE добавени 2026-05-27)

```nim
let sub = Query.fromSchema(Order).select("user_id").where("total", Gt, "100")
let q = Query.fromSchema(User).where("id", InSubquery, sub)

# CTE:
let cte = Query.fromSchema(Order).groupBy("user_id").aggregate(AggSum, "total", "total_spent")
Query.withCte("user_totals", cte).fromSchema(User).joinCte("user_totals", "id", "user_id")
```

### 3.8 Window functions

```nim
Query.fromSchema(Sale)
  .window("w", partitionBy = @["department"], orderBy = @("amount", Desc))
  .select("*", over(AggRank, "w", alias = "rank_within_dept"))
```

### 3.9 Connection pool metrics → Prometheus

```nim
let metrics = repo.poolMetrics()
# metrics.toPrometheus() → # HELP necto_pool_active_connections ...
```

### 3.10 Query timeout и slow query log

Вече има основа в `PostgresAdapter`. Да се добави:
- `statement_timeout` per query
- Slow query log с caller location (via `instantiationInfo`)

---

## Фаза 4: Ecosystem & Benchmark Dominance (Седмица 9–12)

### 4.1 Публикувани benchmarks срещу Ecto, Avram, Norm, SQLx

Docker compose setup: PostgreSQL + benchmark runners. Метрики:
- PK lookup latency (p50, p99)
- INSERT throughput
- SELECT 1000 rows (memory + latency)
- Preload N+1 safe vs lazy loading
- Compile time
- Binary size

### 4.2 Typed JSONB `jsonb_extract_path` query helpers

```nim
Query.fromSchema(User)
  .whereJsonbPath("settings", "notifications.email", Eq, "true")
```

Генерира `jsonb_extract_path(settings, 'notifications', 'email') = 'true'`.

### ✅ 4.3 Multi-tenant support (`schema_prefix`) (ГОТОВО — 2026-05-27)

```nim
necto_schema Post:
  table "posts"
  schema_prefix "tenant_42"  # → "tenant_42"."posts"
```

### 4.4 Karax форм интеграция

```nim
# HTML форма → Changeset директно
let cs = form.toChangeset(User)  # Nim macro генерира от HTML form fields
```

### 4.5 `necto_auth` модул

Готова схема за `User`, `Session`, `PasswordReset` със secure defaults (bcrypt, token rotation).

---

## Тактически избори (2 подхода)

### Подход A: "Nim Superpowers First" (Препоръчителен)

**Приоритет:**
1. Фаза 0 (бъгфиксове)
2. Фаза 2 (Nim superpowers) — това е диференциаторът
3. Фаза 1 (Ecto parity) — само Multi и many_to_many
4. Фаза 3 (production)

**Предимства:**
- По-бързо се отличаваме от Ecto
- Community-то идва заради уникални фичъри
- Малко код, голям ефект

**Недостатъци:**
- Някои production потребители може да липсват savepoints/soft deletes

### Подход B: "Full Ecto Parity First"

**Приоритет:**
1. Фаза 0 (бъгфиксове)
2. Фаза 1 (цялата Ecto parity — Multi, embeds, many_to_many, savepoints, upserts, change migrations)
3. Фаза 3 (production readiness)
4. Фаза 2 (Nim superpowers)

**Предимства:**
- По-лесно мигриране от Ecto/Crystal
- По-пълноценен за production

**Недостатъци:**
- Ставаме "още един Ecto clone" — по-трудно да се отличим
- Повече код, повече време

---

## Метрики за успех

| Метрика | Текущо | Цел (3 месеца) |
|---------|--------|----------------|
| Тестове | 27 suite | 30+ suite |
| Редове код | ~5,000 | ~12,000 |
| Валидатори | 7 | 15+ |
| Query ops | 12 | 30+ |
| QPS vs raw SQL | 75-91% | >95% |
| Compile time (празен проект) | <2s | <2s |
| Binary size overhead | ~0 | ~0 (zero-cost) |
| GitHub stars | ? | 200+ |
| Реални проекти | ? | 3+ |

---

## Философия (не се променя)

- **No lazy loading.** Явен preload винаги.
- **No string interpolation в SQL.** Placeholders навсякъде.
- **Schema не знае за Repo.** Чисто разделение.
- **Zero runtime dependencies.** Само `db_connector` + stdlib.
