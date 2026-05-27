# План за утре — Necto типова система, Фаза 2 + 3

## Контекст

Фаза 1 е готова: JsonNode, Date, TimeOfDay, Uuid, int16 — всички работят (load/dump/schema/migrations).

---

## Фаза 2: Средна сложност (основна работа за утре) ✅ ГОТОВО

### 1. PostgreSQL масиви (`seq[T]`) — приоритет: ВИСОК ✅
- [x] `loadValue*[T](val: string, OptT: typedesc[seq[T]]): seq[T]`
- [x] `dumpValue*[T](val: seq[T]): string`
- [x] `dbType*[T](SeqT: typedesc[seq[T]]): string = dbType(T) & "[]"`
- [x] `dbTypeForNim` за `seq[T]` → `T[]`
- [x] `pgTypeToNim` за PostgreSQL array types: `integer[]` → `seq[int]`, `text[]` → `seq[string]`, и т.н.
- [x] Парсер за PostgreSQL array текстов формат с quoting, escaping, NULL и вложени масиви

### 2. Bytea (`seq[byte]`) — приоритет: СРЕДЕН ✅
- [x] `loadValue*(val: string, T: typedesc[seq[byte]]): seq[byte]` — hex формат `\xDEADBEEF`
- [x] `dumpValue*(val: seq[byte]): string`
- [x] `dbType*(T: typedesc[seq[byte]]): string = "bytea"`

### 3. Enum тип — приоритет: СРЕДЕН ✅
- [x] Generic overload-ове за `dbType`, `loadValue`, `dumpValue`, `castValue` за `T: enum`
- [x] Store-ва се като `text` (името на enum стойността) — Ecto-style
- [x] Работи директно с Nim enum-ове: `type Status = enum Draft, Published, Archived`
- [x] Интеграция в `schema.nim` макрото — `field status: Status`

### 4. Decimal/Numeric — приоритет: СРЕДЕН ✅
- [x] `Decimal = distinct string` — лека имплементация, PostgreSQL сам конвертира
- [x] `dbType*(T: typedesc[Decimal]): string = "numeric"`
- [x] `loadValue`, `dumpValue`, `castValue` за Decimal
- [x] `pgTypeToNim` мапва `numeric`/`decimal` → `Decimal` вместо `float64`

---

## Фаза 3: Архитектура (ако остане време)

### 5. Формален `NectoType` trait/system
**Защо:** Позволява на потребителите да дефинират custom types без да знаят кои proc-ове да overload-нат.

**Идея:**
```nim
# type_system.nim
proc dbType*(T: typedesc): string {.base.} = "text"
proc castValue*(val: string, T: typedesc): T {.base.} = default(T)
proc loadValue*(val: string, T: typedesc): T {.base.} = default(T)
proc dumpValue*(val: auto): string {.base.} = $val

# Потребител:
type Money* = distinct int64  # cents
proc dbType*(T: typedesc[Money]): string = "bigint"
proc loadValue*(val: string, T: typedesc[Money]): Money = Money(parseInt(val))
proc dumpValue*(val: Money): string = $int64(val)
```

Вече е почти така — само трябва да се документира и да има един пример.

### 6. Postgres-specific extensions (optional модул)
**Типове:** `inet`, `cidr`, `macaddr`, `point`, `line`, `circle`, `interval`, `tsvector`, `tsquery`, `ltree`

**Идея:** `import necto/postgres_types` — separate модул, който не замърсява core.

---

## Резултати

- Всички промени са в `type_system.nim`, `schema.nim`, `schema_generator.nim`
- Нов тест: `tests/t_phase2_types.nim` — масиви, bytea, enum, decimal
- Всички съществуващи тестове продължават да минават
