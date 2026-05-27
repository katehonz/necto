# Schema

Schemas define the shape of your data. Necto uses the `necto_schema` macro to generate a Nim type, metadata, constructor, and row loader.

## Basic Schema

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  field age: int
  timestamps
```

### Generated Artifacts

| Name | Type | Purpose |
|------|------|---------|
| `User` | `ref object` | Runtime data holder |
| `UserSchema` | `SchemaMeta` | Reflection (table name, fields, associations) |
| `newUser()` | `proc` | Constructor with defaults |
| `loadUser(row)` | `proc` | Convert `DbRow` → `User` |
| `schemaMeta(User)` | `proc` | Typedesc dispatch for metadata |
| `load(row, User)` | `proc` | Typedesc dispatch for loading |
| `getFieldVal` | `template` | Compile-time field access |
| `setFieldVal` | `template` | Compile-time field assignment |
| `getFieldValRuntime` | `proc` | Runtime field access (returns `string`) |
| `verifyUserSchema()` | `proc` | Schema verification (when `verify` is used) |

## Field Pragmas

| Pragma | Effect |
|--------|--------|
| `primary_key` | Marks the PK; used in UPDATE/DELETE WHERE clauses |
| `auto_increment` | Omits from INSERT, returned via `RETURNING` |
| `not_null` / `null_false` | `nullable = false` in `FieldMeta` |
| `unique` | `unique = true` in `FieldMeta` |

## Supported Types

### Built-in Types

| Nim Type | PostgreSQL Type | Notes |
|----------|-----------------|-------|
| `string` | `text` | |
| `int` | `integer` | 32-bit |
| `int16` | `smallint` | |
| `int64` | `bigint` | |
| `float` | `double precision` | |
| `bool` | `boolean` | |
| `DateTime` | `timestamp with time zone` | from `std/times` |
| `Date` | `date` | custom type, parsed from `yyyy-MM-dd` |
| `TimeOfDay` | `time without time zone` | custom type, parsed from `HH:mm:ss` |
| `JsonNode` | `jsonb` | from `std/json` |
| `Uuid` | `uuid` | `distinct string`, pass-through |
| `Decimal` | `numeric` | `distinct string`, exact precision |
| `seq[byte]` | `bytea` | binary data, hex-encoded |

### Generic Wrappers

| Nim Type | PostgreSQL Type | Notes |
|----------|-----------------|-------|
| `Option[T]` | same as `T` | nullable column |
| `seq[T]` | `T[]` | PostgreSQL array |
| `JsonB[T]` | `jsonb` | **Typed JSONB** — serializes/deserializes to Nim object |

### Enum Types

Nim `enum` types stored as `text` (enum member name):

```nim
type Status = enum Draft, Published, Archived

necto_schema Article:
  table "articles"
  field id: int64 {.primary_key.}
  field status: Status
```

### PostgreSQL-specific Types

Import `necto/postgres_types` for these types:

```nim
import necto/postgres_types
```

| Nim Type | PostgreSQL Type |
|----------|-----------------|
| `PgPoint` | `point` |
| `PgInet` | `inet` |
| `PgCidr` | `cidr` |
| `PgMacAddr` | `macaddr` |
| `PgTsVector` | `tsvector` |
| `PgTsQuery` | `tsquery` |
| `Money` | `bigint` (cents, `distinct int64`) |

### Custom Types

Define your own types by implementing the NectoType interface:

```nim
type MyMoney = distinct int64

proc dbType*(T: typedesc[MyMoney]): string = "bigint"
proc loadValue*(val: string, T: typedesc[MyMoney]): MyMoney =
  MyMoney(parseBiggestInt(val))
proc dumpValue*(val: MyMoney): string = $int64(val)
proc castValue*(val: string, T: typedesc[MyMoney]): MyMoney =
  MyMoney(parseBiggestInt(val))

registerNectoType(MyMoney)  # enables use in necto_schema
```

See `src/necto/postgres_types.nim` for a complete example (`Money` type).

## Typed JSONB (`JsonB[T]`)

A Necto **superpower** — store JSONB in PostgreSQL but access it as a typed Nim object:

```nim
type UserSettings = object
  theme: string
  notifications: bool

necto_schema User:
  table "users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string
  field settings: JsonB[UserSettings]
```

Usage:

```nim
let user = repo.one(fromSchema(User).where("id", Eq, "1")).get()
echo user.settings.val.theme        # "dark"
echo user.settings.val.notifications # true

# Update
var cs = newChangeset(user, {"settings": """{"theme":"light","notifications":false}"""}.toTable)
cs = cs.castFields(@["settings"])
repo.update!(cs)
```

Under the hood, `JsonB[T]` uses `%` and `to()` from Nim's `std/json` for serialization. PostgreSQL stores the raw JSONB; Necto gives you typed access.

## Timestamps

`timestamps` adds `created_at` and `updated_at` automatically:

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  timestamps
```

Both are `DateTime` and auto-populated on INSERT and UPDATE.

## Schema Verification

Add `verify` to your schema to enable compile-time checks against the real database:

```nim
necto_schema User:
  table "users"
  verify                       # ← checks against live DB
  field id: int64 {.primary_key, auto_increment.}
  field email: string {.not_null, unique.}
  field name: string
  timestamps
```

Compile with `-d:nectoVerify` or set `NECTO_VERIFY=1`:

```bash
NECTO_VERIFY=1 nim c -r my_app.nim
```

At startup (before any queries), Necto connects to the database and verifies:
- Table exists
- All declared columns exist with compatible types
- NOT NULL constraints match
- PRIMARY KEY constraint exists
- UNIQUE constraints exist (warning only)

Mismatches produce clear error messages and stop the program. Warnings are printed but don't abort.

**CI/CD:** Use the standalone `necto_verify` CLI tool:

```bash
nimble verify -- --table=users \
  --field=id:int64:bigint:pk:notnull \
  --field=name:string:text:notnull
```

See [Schema Verification](./verification.md) for full details.

## Associations

### belongs_to

Adds an FK column (e.g. `author_id: int64`) and `AssocMeta`:

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  belongs_to author: User
  timestamps
```

### has_many

Adds a virtual `seq[Child]` field and `AssocMeta`:

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  field name: string
  has_many posts: Post
```

> **Note:** Define the child schema **before** the parent to avoid forward-reference issues.

### has_one

Similar to `has_many` but expects a single child:

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  has_one profile: Profile
```

### many_to_many

Join-table association with automatic preload:

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  many_to_many roles: Role through "user_roles"
```

Adds a virtual `roles: seq[Role]` field. The join table is specified via `through`.

## Soft Deletes

Add `soft_deletes` to mark records as deleted instead of removing them:

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  soft_deletes
```

This adds `deleted_at: Option[DateTime]` and changes delete behavior:
- `repo.delete(cs)` → `UPDATE SET deleted_at = NOW()`
- `repo.hardDelete(cs)` → true `DELETE`
- Queries auto-filter `WHERE deleted_at IS NULL`
- `.includeDeleted()` / `.onlyDeleted()` query modifiers

## Embedded Schemas

Store nested Nim objects in a single JSONB column:

```nim
type Profile = object
  bio: string
  avatar_url: string

necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  embeds_one profile: Profile  # stored as JSONB
```

`embeds_many` stores a JSONB array:

```nim
type Address = object
  street: string
  city: string

necto_schema User:
  embeds_many addresses: Address
```

## Multi-Tenant (schema_prefix)

Route queries to different PostgreSQL schemas:

```nim
necto_schema Post:
  table "posts"
  schema_prefix "tenant_42"  # → "tenant_42"."posts"
  field id: int64 {.primary_key.}
  field title: string
```

Runtime override:

```nim
repo.setTenant("tenant_99")
let posts = repo.all(fromSchema(Post))  # → "tenant_99"."posts"
repo.clearTenant()  # back to schema_prefix
```

## Reverse Schema Generation

If you already have a PostgreSQL database, Necto can introspect it and generate the schema code for you.

### CLI

```bash
nim c -r src/necto_gen_schema.nim \
  --table=users \
  --host=localhost \
  --port=5432 \
  --user=postgres \
  --password=secret \
  --database=my_app \
  --output=src/models/user.nim
```

### Programmatic

```nim
import necto/schema_generator
import db_connector/db_postgres

let conn = open("localhost", "postgres", "secret", "my_app")
let info = inspectTable(conn, "users")
echo generateSchema(info, schemaName = "User")
close(conn)
```

### Supported Type Mappings

| PostgreSQL Type | Generated Nim Type |
|-----------------|-------------------|
| `bigint`, `bigserial` | `int64` |
| `integer`, `serial` | `int` |
| `smallint` | `int16` |
| `text`, `varchar` | `string` |
| `boolean` | `bool` |
| `double precision` | `float` |
| `timestamp with time zone` | `DateTime` |
| `date` | `Date` |
| `time without time zone` | `TimeOfDay` |
| `jsonb`, `json` | `JsonNode` |
| `uuid` | `Uuid` |
| `numeric`, `decimal` | `Decimal` |
| `bytea` | `seq[byte]` |
| `T[]` (array) | `seq[T]` |
| any nullable column | `Option[T]` |

`bigserial` / `serial` columns are detected automatically and marked with `{primary_key, auto_increment}`.

## Reflection

```nim
echo UserSchema.tableName        # "users"
echo UserSchema.fields.len       # 6
for f in UserSchema.fields:
  echo f.name, " -> ", f.dbType

for a in UserSchema.associations:
  echo a.name, " (", a.kind, ")"
```
