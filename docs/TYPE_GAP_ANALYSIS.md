# Анализ: Necto спрямо Ecto и Avram — Актуално състояние

> **Важно:** Този документ беше напълно преработен на 2026-05-27. Предишната версия
> описваше липси, които вече са имплементирани. Ако сте чели старата версия —
> почти всичко вече работи.

## Резюме

Necto има **пълна поддръжка на всички скаларни PostgreSQL типове**, включително
UUID, Decimal, Date/Time, JSONB, масиви, bytea и Enum. Критичните липси са вече
на ниво архитектура — `many_to_many`, embedded schemas, composable transactions
и production readiness фичъри.

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

## Какво липсва (архитектурно ниво)

### 1. `many_to_many` асоциации
Necto има само `belongs_to`, `has_many`, `has_one`. `many_to_many` с join таблица
е най-често искания missing feature.

### 2. Embedded schemas (`embeds_one` / `embeds_many`)
Ecto позволява nested обекти със свой changeset, запазени в една колона (`jsonb`).
Necto има `JsonB[T]` за typed JSON, но без nested changeset/validation lifecycle.

### 3. Composable transactions (`Ecto.Multi` еквивалент)
Necto има императивен `transaction` блок, но не и именуван pipeline от операции
с dependency graph и rollback на целия pipeline.

### 4. Savepoints / nested transactions
Вложени `transaction()` блокове отварят нова връзка вместо PostgreSQL `SAVEPOINT`.

### 5. Upserts (`ON CONFLICT`)
Липсва `INSERT ... ON CONFLICT DO NOTHING/UPDATE`.

### 6. `change` direction за миграции
Само explicit `up` / `down`. Няма auto-reversible `change` като в Ecto.

### 7. Streaming (`repo.stream`)
Липсва cursor-based streaming за големи резултати.

### 8. Soft deletes
Няма built-in `deleted_at` + `.excludeDeleted()` модел.

---

## Nim Superpowers (където вече водим)

| Способност | Necto | Ecto | Коментар |
|-----------|-------|------|----------|
| **Zero-cost абстракции** | ✅ | ❌ | Компилира до C, няма runtime overhead |
| **Single binary deployment** | ✅ | ❌ | Zero Erlang/Elixir runtime dependencies |
| **Typed JSONB** `JsonB[T]` | ✅ | ❌ | Nim типова сериализация в JSONB |
| **Compile-time schema verification** | ✅ | ❌ | `-d:nectoVerify` проверява таблици/колони при компилация |
| **Compile-time query verification** | ✅ | ❌ | EXPLAIN-based validation при стартиране |
| **Schema reverse engineering** | ✅ | ❌ | `necto_gen_schema` от `information_schema` |
| **Compiled query cache** | ✅ | ❌ | `compileQuery()` за zero runtime SQL gen |
| **Connection pool metrics** | ✅ | ❌ | wait time, active conns, queue depth |
| **Read replica support** | ✅ | ❌ | `read_host` / `read_port` routing |

---

## План за догонване → Изпреварване

Вж. `ROADMAP.md` за детайлен план. Приоритет:
1. **Фаза 0:** Бъгфиксове (вече в progress)
2. **Фаза 1:** Ecto parity — Multi, many_to_many, embeds, savepoints, upserts
3. **Фаза 2:** Nim Superpowers — compile-time JSON paths, zero-copy arrays, fixed-point Decimal
4. **Фаза 3:** Production ready — streaming, soft deletes, migration locking, FTS
5. **Фаза 4:** Ecosystem — benchmarks, integrations, auth module
