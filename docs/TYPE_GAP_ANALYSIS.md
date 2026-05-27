# Анализ: Какво липсва на necto спрямо Ecto и Avram

## Резюме

Necto има **основните скалари**, но липсват критични типове за production PostgreSQL приложения — UUID, Decimal, Date/Time, масиви, Enum и пълноценна JSON поддръжка. Този документ описва разликите и план за догонване.

---

## Сравнителна таблица

| Тип | PostgreSQL | Necto (сега) | Ecto | Avram | Липса |
|-----|-----------|--------------|------|-------|-------|
| `string` | `text`, `varchar` | ✅ `string` | ✅ `:string` | ✅ `String` | — |
| `int` | `integer` | ✅ `int` | ✅ `:integer` | ✅ `Int32` | — |
| `int64` | `bigint` | ✅ `int64` | ✅ `:id`/`:integer` | ✅ `Int64` | — |
| `int16` | `smallint` | ❌ — | ✅ `:integer` | ✅ `Int16` | **Няма тип** |
| `float` | `double precision` | ✅ `float` | ✅ `:float` | ✅ `Float64` | — |
| `bool` | `boolean` | ✅ `bool` | ✅ `:boolean` | ✅ `Bool` | — |
| `DateTime` | `timestamptz` | ✅ `DateTime` | ✅ `:utc_datetime` | ✅ `Time` | — |
| `Date` | `date` | ❌ — | ✅ `:date` | ❌? | **Няма тип** |
| `Time` | `time`, `timetz` | ❌ — | ✅ `:time` | ✅ `Time` | **Няма тип** |
| `JsonNode` | `json`, `jsonb` | ⚠️ Частично | ✅ `:map` | ✅ `JSON::Any` | **load/dump липсват** |
| `UUID` | `uuid` | ❌ — | ✅ `Ecto.UUID` | ✅ `UUID` | **Няма тип** |
| `Decimal` | `numeric`, `decimal` | ❌ (float) | ✅ `:decimal` | ✅ `PG::Numeric` | **Няма тип** |
| `seq[T]` | масиви | ❌ placeholder | ✅ `{:array, T}` | ✅ `Array(T)` | **Няма имплементация** |
| `Enum` | `integer`/`string` | ❌ — | ✅ `Ecto.Enum` | ✅ `Enum` | **Няма тип** |
| `bytea` | `bytea` | ⚠️ schema gen only | ✅ `:binary` | ✅ `Bytes` | **Няма load/dump** |
| Custom types | — | ⚠️ ad-hoc overload | ✅ `Ecto.Type` behaviour | ⚠️ extensions | **Няма формална система** |

---

## Детайли по липсите

### 1. JsonNode — частично (Критично)
- `dbType` и `dbTypeForNim` работят (`jsonb`)
- **Липсват** `loadValue*(val: string, T: typedesc[JsonNode]): JsonNode`
- **Липсват** `dumpValue*(val: JsonNode): string`
- Schema generator го разпознава, но компилация спира при `repo.all()` или `repo.insert()`

### 2. UUID — липсва напълно
- Няма Nim тип, няма PostgreSQL mapping
- Ecto го има като `Ecto.UUID` (custom type)
- Avram го има като `UUID` (crystal std)

### 3. Date (само дата) — липсва
- Nim има `Date` в `times` модул
- PostgreSQL има `date`
- Necto има само `DateTime` → `timestamp with time zone`

### 4. Time (само час) — липсва
- Nim има `Time` в `times` модул
- PostgreSQL има `time`, `time with time zone`
- Ecto има `:time`, `:time_usec`

### 5. Decimal/Numeric — липсва
- Nim **няма** вграден `Decimal` тип (за разлика от Elixir)
- PostgreSQL `numeric`/`decimal` е критичен за пари
- Трябва да се избере/имплементира библиотека

### 6. Масиви (`seq[T]`) — placeholder
- `loadValue*[T](val: string, OptT: typedesc[seq[T]]): seq[T]` връща `@[]`
- `dumpValue*[T](val: seq[T]): string` връща `"{}"`
- PostgreSQL масивите са пълноценен тип — `{1,2,3}`, `{"a","b"}`
- Ecto поддържа `{:array, inner_type}`

### 7. Enum — липсва
- PostgreSQL има `ENUM` типове
- Ecto има `Ecto.Enum` (parameterized type, stored as string/int)
- Типичен use-case: `status: :draft | :published | :archived`

### 8. Bytea/Binary — липсва
- Schema generator мапва `bytea` → `seq[byte]`
- Но няма `loadValue`/`dumpValue` за `seq[byte]`
- PostgreSQL `bytea` изисква escape/unescape (`\x` формат)

### 9. Custom Type System — ad-hoc
- Ecto има формален `Ecto.Type` behaviour: `type/0`, `cast/1`, `load/1`, `dump/1`, `equal?/2`, `embed_as/1`
- Necto има коментар в `type_system.nim`: "overload на `dbType`, `castValue`, `loadValue`, `dumpValue`"
- Но няма формален `NectoType` trait/concept — потребителят трябва да знае кои proc-ове да overload-не

---

## План: Догонване → Изпреварване

### Фаза 1: Бързи победи (1-2 дни)

| Задача | Файл | Описание |
|--------|------|----------|
| JsonNode load/dump | `type_system.nim` | `parseJson(val)` и `$val` |
| Date / Time | `type_system.nim`, `schema.nim`, `schema_generator.nim` | Добавяне на `Date` и `Time` от `std/times` |
| UUID | `type_system.nim`, `schema_generator.nim` | Ново `Uuid` тип (може `array[16, byte]` или `string` wrapper) |
| Int16 | `type_system.nim`, `schema_generator.nim` | `int16` → `smallint` |

### Фаза 2: Средна сложност (3-5 дни)

| Задача | Файл | Описание |
|--------|------|----------|
| PostgreSQL масиви | `type_system.nim` | Парсване на `{a,b,c}` формат за `seq[T]`. Рекурсивно за вложени? |
| Bytea | `type_system.nim` | `seq[byte]` ↔ PostgreSQL `bytea` hex escape |
| Enum тип | нов файл `enum_type.nim` | Parameterized тип като в Ecto — `EnumType(["draft", "published"])` |
| Decimal | research | Оценка на Nim библиотеки: `decimal`, `bignum`, или custom `Decimal` object |

### Фаза 3: Архитектура (1 седмица)

| Задача | Файл | Описание |
|--------|------|----------|
| `NectoType` trait/system | нов файл `custom_type.nim` | Формален интерфейс за custom types, подобен на `Ecto.Type` behaviour |
| Parameterized types | `schema.nim` | Поддръжка на типове с параметри — `EnumType(values)`, `ArrayType(inner)` |
| Postgres-specific extensions | `adapters/postgres_extensions.nim` | `inet`, `cidr`, `point`, `line`, `interval`, `tsvector` — като optional модул |

### Фаза 4: Изпреварване — уникални за necto (бонус)

| Идея | Защо е уникално |
|------|----------------|
| **Compile-time type-safe JSON paths** | Nim macro-та могат да проверяват `user.settings["theme"]` на compile time |
| **Zero-copy array loading** | Масивите се парсват директно от PostgreSQL wire формат без междинен string |
| **Integrated JSONB query operators** | `where("data", @> JsonNode)` — natively в query builder |
| **Decimal като fixed-point** | `int64` backing със зададен scale — по-бързо от arbitrary precision |

---

## Приоритет

1. **JsonNode load/dump** — блокира всеки, който иска да ползва JSONB
2. **UUID** — почти всяка модерна PostgreSQL база ползва UUID PK
3. **Date / Time** — стандартни типове, лесни за добавяне
4. **Decimal** — критичен за финанси, но изисква dependency
5. **Масиви** — важни за advanced PostgreSQL
6. **Enum** — качество на живота, но workaround-ва се с `string`/`int`
7. **Custom type system** — needed за екосистема от плъгини
