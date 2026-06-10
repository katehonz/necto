# MariaDB Adapter за Necto ORM — Design Spec

## Цел
Добавяне на MariaDB поддръжка към Necto ORM (в момента само PostgreSQL), като се запази съществуващият API и архитектура.

## Контекст
- Necto използва **адаптерен модел**: `base.nim` дефинира интерфейс, `postgres.nim` го имплементира.
- Query builder-ът генерира SQL с `$N` placeholders (PostgreSQL стил).
- Type system-ът е силно PostgreSQL-ориентиран (`jsonb`, `bytea`, `bigserial`, `timestamp with time zone`).
- Миграциите генерират PostgreSQL DDL.
- Repo слоят генерира `ON CONFLICT`, `RETURNING`, `EXCLUDED.` — PostgreSQL специфики.

## Архитектура — Pragmatic Adapter с SQL Translation

Вместо да се пренаписва query builder и миграции, се използва **layered approach** с минимални промени в съществуващия код:

```
┌─────────────────────────────────────┐
│  Query Builder, Repo, Schema, etc.  │  ← без промяна
├─────────────────────────────────────┤
│  SQL Translation Layer ($N → ?)     │  ← нов, тънък слой
├─────────────────────────────────────┤
│  MariaDB Adapter (mariadb.nim)      │  ← нова имплементация на base.nim
├─────────────────────────────────────┤
│  db_connector/db_mysql              │  ← Nim stdlib driver
├─────────────────────────────────────┤
│  libmariadb / libmysqlclient        │  ← C библиотека
└─────────────────────────────────────┘
```

## Компоненти

### 1. MariaDB Adapter (`src/necto/adapters/mariadb.nim`)

Имплементира `base.nim` интерфейса:

- `connect` / `disconnect` — с connection pooling (аналогично на PostgresAdapter)
- `query` / `exec` / `execAffected` / `scalar` — през `db_mysql`
- `insertReturning` — **emulated**: `INSERT` → `SELECT LAST_INSERT_ID()`
- `fetchCursor` — **emulated** чрез `LIMIT/OFFSET` (server-side курсори не се използват)
- `beginTransaction` / `commitTransaction` / `rollbackTransaction` / `savepoint` / `rollbackToSavepoint` — стандартни SQL команди
- **Placeholder translation**: `$1, $2, ...` → `?, ?, ...` преди изпращане към driver

**Connection параметри**:
- Default port: 3306
- Character set: UTF-8

### 2. SQL Translation (`$N` → `?`)

MySQL/MariaDB driver-ът използва `?` placeholders вместо `$N`. Преводът става в адаптера:

```nim
proc translatePlaceholders(sql: string): string =
  # "SELECT * FROM users WHERE id = $1 AND name = $2"
  # → "SELECT * FROM users WHERE id = ? AND name = ?"
```

Този подход **не изисква промяна** в `query.nim`, `repo.nim` или други модули.

### 3. Repo Overrides за MariaDB

Някои операции в `repo.nim` са PostgreSQL-специфични и трябва да се адаптират за MariaDB:

| Feature | PostgreSQL | MariaDB |
|---------|-----------|---------|
| `insertReturning` | `INSERT ... RETURNING id` | `INSERT ...; SELECT LAST_INSERT_ID()` |
| Upsert | `ON CONFLICT DO UPDATE` | `ON DUPLICATE KEY UPDATE` |
| Soft delete | `NOW()` | `NOW()` (еднакво) |
| Batch insert | `RETURNING *` | `INSERT` + отделни `SELECT` за reload (или без reload) |

**Подход**: В `repo.nim` ще се добавят adapter-type проверки или нови методи в базовия адаптер за dialect-специфично поведение.

По-чист подход: добавяне на `dialect` поле в `Adapter` базовия тип:

```nim
type
  SqlDialect* = enum
    pdPostgres, pdMariaDb

  Adapter* = ref object of RootObj
    # ... existing fields ...
    dialect*: SqlDialect
```

И методи като:
- `insertReturningSql(adapter, sql, pkName)` — връща dialect-специфичен SQL
- `upsertSql(adapter, ...)` — връща `ON CONFLICT` или `ON DUPLICATE KEY UPDATE`

### 4. Type Mapping (PostgreSQL → MariaDB)

| PostgreSQL | MariaDB | Забележка |
|-----------|---------|-----------|
| `bigserial` | `BIGINT AUTO_INCREMENT PRIMARY KEY` | Emulated — MariaDB няма `SERIAL` като тип, но има `AUTO_INCREMENT` |
| `serial` | `INT AUTO_INCREMENT PRIMARY KEY` | — |
| `integer` | `INT` | — |
| `smallint` | `SMALLINT` | — |
| `bigint` | `BIGINT` | — |
| `text` | `TEXT` | — |
| `boolean` | `TINYINT(1)` | MariaDB няма native boolean |
| `double precision` | `DOUBLE` | — |
| `timestamp with time zone` | `DATETIME(6)` | MariaDB няма `timestamptz` |
| `timestamp without time zone` | `DATETIME(6)` | — |
| `date` | `DATE` | — |
| `time without time zone` | `TIME` | — |
| `jsonb` | `JSON` | MariaDB 10.2+ поддържа JSON |
| `json` | `JSON` | — |
| `uuid` | `CHAR(36)` | MariaDB няма native UUID тип |
| `numeric` | `DECIMAL(38, 10)` | — |
| `bytea` | `BLOB` | — |
| `text[]` | **не се поддържа** | Arrays са PostgreSQL-специфични |

**Имплементация**: Добавяне на `mariadbTypeMappings` proc или adapter метод `translateDbType(pgType: string): string`.

### 5. Migration SQL Generators за MariaDB

DDL синтаксисът на MariaDB се различава от PostgreSQL:

- **`CREATE TABLE`**: MariaDB няма `IF NOT EXISTS` в стари версии (има го от 10.1+), но ще го ползваме.
- **`BIGSERIAL`**: → `BIGINT AUTO_INCREMENT PRIMARY KEY`
- **`DROP TABLE IF EXISTS`**: работи и в двете.
- **`ALTER TABLE ... DROP COLUMN IF EXISTS`**: MariaDB **няма** `IF EXISTS` за `DROP COLUMN`. Ще се генерира без `IF EXISTS` или с `IF EXISTS` ако версията го поддържа (MariaDB 10.2.8+).
- **`ALTER TABLE ... RENAME COLUMN`**: MariaDB използва `CHANGE COLUMN old_name new_name type` вместо `RENAME COLUMN`.
- **`ALTER TABLE ... ALTER COLUMN ... TYPE`**: MariaDB използва `MODIFY COLUMN`.
- **`ALTER TABLE ... ALTER COLUMN ... SET DEFAULT`**: MariaDB: `ALTER COLUMN ... SET DEFAULT` работи.
- **`ALTER TABLE ... ALTER COLUMN ... SET NOT NULL`**: MariaDB: `ALTER COLUMN ... SET NOT NULL` работи.
- **Constraints**: `ADD CONSTRAINT` работи, но `DROP CONSTRAINT IF EXISTS` може да има различно поведение.

**Подход**: Добавяне на `dialect`-aware SQL generator helper-и в `migration.nim` или отделен `mariadb_migrations.nim` модул.

По-чисто: `createTableSql`, `dropTableSql`, и др. да приемат `SqlDialect` параметър.

## Emulated Features

### insertReturning
```sql
-- PostgreSQL
INSERT INTO users (name) VALUES (?) RETURNING id;

-- MariaDB
INSERT INTO users (name) VALUES (?);
SELECT LAST_INSERT_ID();
```

### Streaming (LIMIT/OFFSET)
Вместо server-side курсори, `StreamIterator` за MariaDB ще използва `LIMIT batchSize OFFSET currentOffset`:
```sql
SELECT * FROM users WHERE active = 1 LIMIT 100 OFFSET 0;
SELECT * FROM users WHERE active = 1 LIMIT 100 OFFSET 100;
-- ...
```

### Upsert (ON DUPLICATE KEY UPDATE)
```sql
-- PostgreSQL
INSERT INTO users (id, name) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

-- MariaDB
INSERT INTO users (id, name) VALUES (?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name);
```

## Ограничения (PostgreSQL-only features)

Следните функции остават **PostgreSQL-only** и при използване с MariaDB ще вдигат грешка:

1. **JSONB оператори** (`@>`, `?`, `#>>`, `#>`) — MariaDB има различен JSON API (`JSON_EXTRACT`, `JSON_CONTAINS`)
2. **Arrays** (`seq[T]` полета) — MariaDB няма native array тип
3. **Full-text search** (`to_tsvector`, `plainto_tsquery`, `@@`) — MariaDB използва `MATCH ... AGAINST`
4. **CTE (`WITH`)** — MariaDB 10.2+ поддържа CTE, но може да има разлики
5. **Window functions** — MariaDB 10.2+ поддържа повечето, но тестване е нужно

## Тестване

1. **Unit тестове** за `mariadb.nim` adapter-а (mock connection)
2. **Интеграционен тест** с реална MariaDB база:
   - host: `localhost`
   - user: `root`
   - password: `pas+123`
   - database: `necto`
   - port: 3306

## Dependencies

- `db_connector >= 0.1.0` (вече е dependency) — съдържа `db_mysql`
- MariaDB клиент библиотека (`libmariadb` или `libmysqlclient`)

## Файлове за промяна/създаване

| Файл | Действие |
|------|----------|
| `src/necto/adapters/mariadb.nim` | Нов — MariaDB adapter имплементация |
| `src/necto/adapters/base.nim` | Промяна — добавяне на `dialect` и dialect методи |
| `src/necto/repo.nim` | Промяна — adapter-type проверки за RETURNING, upsert, soft delete |
| `src/necto/migration.nim` | Промяна — dialect-aware DDL generators |
| `src/necto/type_system.nim` | Промяна — `dbType` overloads за MariaDB или dialect-aware mapping |
| `src/necto.nim` | Промяна — export на MariaDB adapter |
| `necto.nimble` | Промяна — добавяне на MariaDB test task |
| `tests/t_mariadb.nim` | Нов — интеграционни тестове за MariaDB |
| `tests/t_mariadb_adapter.nim` | Нов — unit тестове за MariaDB adapter |
