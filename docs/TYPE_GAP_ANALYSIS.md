# Анализ: Necto спрямо Ecto и Avram — Актуално състояние

> **Важно:** Този документ беше напълно преработен на 2026-05-27. Последно обновен на 2026-05-27.

## Резюме

Necto има **пълна поддръжка на всички скаларни PostgreSQL типове**, включително
UUID, Decimal, Date/Time, JSONB, масиви, bytea и Enum. Критичните архитектурни
липси от Фаза 0 и Фаза 1 вече са имплементирани. Текущият фокус е **Фаза 2:
Nim Superpowers** и **Фаза 3: Production ready**.

## Сравнителна таблица

| Тип | PostgreSQL | Necto | Ecto | Avram | Бележка |
|-----|-----------|-------|------|-------|---------|
| `string` | `text`, `varchar` | ✅ `string` | ✅ `:string` | ✅ `String` | — |
| `int` | `integer` | ✅ `int` | ✅ `:integer` | ✅ `Int32` | — |
| `int64` | `bigint` | ✅ `int64` | ✅ `:id`/`:integer` | ✅ `Int64` | — |
| `int16` | `smallint` | ✅ `int16` | ✅ `:integer` | ✅ `Int16` | ✅ Добавен 2026-05 |
| `float` | `double precision` | ✅ `float` | ✅ `:float` | ✅ `Float64` | — |
| `bool` | `boolean` | ✅ `bool` | ✅ `:boolean` | ✅ `Bool` | — |
| `DateTime` | `timestamptz` | ✅ `DateTime` | ✅ `:utc_datetime` | ✅ `Time` | — |
| `Date` | `date` | ✅ `Date` | ✅ `:date` | ❌? | ✅ Добавен 2026-05 |
| `TimeOfDay` | `time` | ✅ `TimeOfDay` | ✅ `:time` | ✅ `Time` | ✅ Добавен 2026-05 |
| `JsonNode` | `json`, `jsonb` | ✅ Пълна | ✅ `:map` | ✅ `JSON::Any` | ✅ load/dump/tested |
| `UUID` | `uuid` | ✅ `Uuid` | ✅ `Ecto.UUID` | ✅ `UUID` | ✅ Добавен 2026-05 |
| `Decimal` | `numeric` | ✅ `Decimal` | ✅ `:decimal` | ✅ `PG::Numeric` | ✅ String wrapper |
| `FixedDecimal[S]` | `numeric` | ✅ `FixedDecimal` | ❌ Няма | ❌ Няма | 🚀 **Nim unique** — int64-backed |
| `seq[T]` | масиви | ✅ Пълна | ✅ `{:array, T}` | ✅ `Array(T)` | ✅ PG array parser |
| `Enum` | `text`/`int` | ✅ `enum` | ✅ `Ecto.Enum` | ✅ `Enum` | ✅ Stored as text |
| `bytea` | `bytea` | ✅ `seq[byte]` | ✅ `:binary` | ✅ `Bytes` | ✅ Hex escape |
| `Option[T]` | nullable | ✅ | ✅ | ✅ | — |
| `JsonB[T]` | `jsonb` | ✅ Typed JSONB | ❌ Няма | ❌ Няма | 🚀 **Уникално за Necto** |
| Custom types | — | ✅ `registerNectoType` | ✅ `Ecto.Type` | ⚠️ extensions | ✅ 4-proc convention |

### PostgreSQL-специфични типове (опционален модул)

| Тип | PostgreSQL | Статус |
|-----|-----------|--------|
| `PgPoint` | `point` | ✅ |
| `PgInet` | `inet` | ✅ |
| `PgCidr` | `cidr` | ✅ |
| `PgMacAddr` | `macaddr` | ✅ |
| `PgTsVector` | `tsvector` | ✅ |
| `PgTsQuery` | `tsquery` | ✅ |
| `Money` | `bigint` (fixed-point) | ✅ Пример custom type |

---

## Имплементирани архитектурни фичъри

### ✅ `many_to_many` асоциации
`many_to_many roles: Role through "user_roles"` с `preloadManyToMany` и
`allWithPreload` поддръжка.

### ✅ Embedded schemas (`embeds_one` / `embeds_many`)
Nested обекти запазени в JSONB колона с typed load/dump. Поддържат `Option[T]`
полета за толерантна десериализация.

### ✅ Composable transactions (`Ecto.Multi` еквивалент)
`NectoMulti` с именувани стъпки, dependency graph и автоматичен rollback
при неуспех. Вж. `src/necto/multi.nim`.

### ✅ Savepoints / nested transactions
`repo.savepoint("name")` блокове + `repo.rollbackTo("name")` чрез PostgreSQL
`SAVEPOINT`.

### ✅ Manual rollback
`repo.rollback()` хвърля `RollbackError`, който `transaction()` хваща gracefully.

### ✅ Upserts (`ON CONFLICT`)
`repo.insert(cs, doNothing())` и `repo.insert(cs, doUpdate("email", @["name"]))`
чрез `INSERT ... ON CONFLICT`.

### ✅ `change` direction за миграции
Auto-reversible `change:` блок с автоматично генериран `down` за `createTable`,
`addColumn`, `addIndex`, `addReference`, `renameTable`, `renameColumn`.

### ✅ JSONB query operators
PostgreSQL JSONB оператори интегрирани в Query builder:
- `@>` — `whereJsonbContains(field, json)`
- `?` — `whereJsonbHasKey(field, key)`
- `?|` — `whereJsonbHasAnyKeys(field, keys)`
- `?&` — `whereJsonbHasAllKeys(field, keys)`
- `#>>` — `whereRawField(jsonbPathText(field, path), op, value)`

### ✅ Fixed-point Decimal
`FixedDecimal[Scale: static int]` — distinct `int64` с zero-allocation
аритметика. Поддържа `fromFloat`, `toFloat`, `$`, `+`, `-`, `*`, `/`.

---

## Какво липсва (бъдещи фази)

### Фаза 2: Nim Superpowers (в progress)
- **Static FK checks** — compile-time foreign key type validation (blocked by CT eval)
- ✅ **Compile-time JSON paths** — `whereJsonbIt(profile.settings.theme == "dark")` macro генерира `#>>` path SQL с compile-time AST extraction
- ✅ **Zero-copy array loading** — slice-based `pgArrayElements` iterator + specialized fast paths за `seq[int]`, `seq[int64]`, `seq[float]`, `seq[bool]`
- **Compile-time query plan caching** — EXPLAIN планове кеширани на compile time

### Фаза 3: Production ready (в progress)
- ✅ **Soft deletes** — `soft_deletes` pragma в schema + `includeDeleted()`/`onlyDeleted()`/`hardDelete()`
- **Streaming** (`repo.stream`) — cursor-based streaming за големи резултати
- **Migration locking** — advisory locks за конкурентни миграции
- **Prepared statement cache** — per-connection кеширане
- **FTS DSL** — type-safe full-text search
- **Subqueries / CTEs** — `WITH` clauses и correlated subqueries
- **Window functions** — `OVER (PARTITION BY ...)`

### Фаза 4: Ecosystem
- **Benchmarks** — сравнителни тестове с Ecto и ActiveRecord
- **Prometheus metrics** — query latency, connection pool
- **Auth module** — готов за употреба authentication

---

## Nim Superpowers (където вече водим)

| Способност | Necto | Ecto | Коментар |
|-----------|-------|------|----------|
| **Zero-cost абстракции** | ✅ | ❌ | Компилира до C, няма runtime overhead |
| **Single binary deployment** | ✅ | ❌ | Zero Erlang/Elixir runtime dependencies |
| **Typed JSONB** `JsonB[T]` | ✅ | ❌ | Nim типова сериализация в JSONB |
| **JSONB query operators** | ✅ | ❌ | `@>`, `?`, `?|`, `?&`, `#>>` в Query builder |
| **Fixed-point Decimal** | ✅ | ❌ | `FixedDecimal[Scale]` — compile-time scaled |
| **Zero-copy array loading** | ✅ | ❌ | Slice-based parsing за `seq[int]`/`seq[int64]`/`seq[float]`/`seq[bool]` |
| **Compile-time JSON paths** | ✅ | ❌ | `whereJsonbIt` macro за type-safe JSONB path queries |
| **Soft deletes** | ✅ | ⚠️ | `soft_deletes` pragma + `includeDeleted()`/`onlyDeleted()` |
| **Compile-time schema verification** | ✅ | ❌ | `-d:nectoVerify` проверява таблици/колони при компилация |
| **Compile-time query verification** | ✅ | ❌ | EXPLAIN-based validation при стартиране |
| **Schema reverse engineering** | ✅ | ❌ | `necto_gen_schema` от `information_schema` |
| **Compiled query cache** | ✅ | ❌ | `compileQuery()` за zero runtime SQL gen |
| **Connection pool metrics** | ✅ | ❌ | wait time, active conns, queue depth |
| **Read replica support** | ✅ | ❌ | `read_host` / `read_port` routing |
