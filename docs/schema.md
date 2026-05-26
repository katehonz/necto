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

## Field Pragmas

| Pragma | Effect |
|--------|--------|
| `primary_key` | Marks the PK; used in UPDATE/DELETE WHERE clauses |
| `auto_increment` | Omits from INSERT, returned via `RETURNING` |
| `not_null` / `null_false` | `nullable = false` in `FieldMeta` |
| `unique` | `unique = true` in `FieldMeta` |

## Supported Types

| Nim Type | PostgreSQL Type |
|----------|-----------------|
| `string` | `text` |
| `int` | `integer` |
| `int64` | `bigint` |
| `float` | `double precision` |
| `bool` | `boolean` |
| `DateTime` | `timestamp with time zone` |
| `JsonNode` | `jsonb` |
| `Option[T]` | `T` (nullable) |

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

## Associations

### belongs_to

Adds an `fk` column (e.g. `author_id: int64`) and `AssocMeta`:

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

## Reflection

```nim
echo UserSchema.tableName        # "users"
echo UserSchema.fields.len       # 6
for f in UserSchema.fields:
  echo f.name, " -> ", f.dbType

for a in UserSchema.associations:
  echo a.name, " (", a.kind, ")"
```
