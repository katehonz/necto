# Associations & Preload

Necto eliminates N+1 queries via **batch preload**. Instead of loading each association individually, it collects all foreign keys, runs a single `IN (...)` query, and maps the results back.

## Defining Associations

### belongs_to

```nim
necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  belongs_to author: User
  timestamps
```

This adds:
- `author_id: int64` field (stored in the database)
- `AssocMeta` for reflection

### has_many

```nim
necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  field name: string
  has_many posts: Post
```

This adds:
- Virtual `posts: seq[Post]` field
- `AssocMeta` with `kind = akHasMany`

> **Order matters:** Define the **child** schema before the **parent** to avoid Nim forward-reference issues.

## Preload

### BelongsTo

```nim
let posts = repo.all(fromSchema(Post).orderBy("id", Asc))
let authors = preloadBelongsTo[Post, User](repo, posts)

for p in posts:
  echo p.title, " by ", authors[p.author_id].name
```

Result: `Table[int64, User]`

### HasMany

```nim
let users = repo.all(fromSchema(User).orderBy("id", Asc))
let userPosts = preloadHasMany[User, Post](repo, users)

for u in users:
  echo u.name, " has ", userPosts[u.id].len, " posts"
  for p in userPosts[u.id]:
    echo "  - ", p.title
```

Result: `Table[int64, seq[Post]]`

### HasOne

```nim
let users = repo.all(fromSchema(User))
let profiles = preloadHasOne[User, Profile](repo, users)

for u in users:
  if profiles.hasKey(u.id):
    echo profiles[u.id].bio
```

Result: `Table[int64, Profile]`

## Auto-Preload Macros

For convenience, Repo provides macros that run the query **and** preload associations in one call:

### allWithPreload

```nim
let posts = repo.allWithPreload(
  fromSchema(Post).orderBy("id", Asc),
  "author"
)
# posts are loaded; authors are batch-preloaded automatically
```

Multiple associations at once:

```nim
let users = repo.allWithPreload(
  fromSchema(User).where("active", Eq, "true"),
  "posts", "profile"
)
```

### oneWithPreload

Same for a single result:

```nim
let maybePost = repo.oneWithPreload(
  fromSchema(Post).where("id", Eq, "42"),
  "author"
)
```

> **Note:** `allWithPreload` / `oneWithPreload` reuse the same connection for both queries and guarantee exactly 2 queries total.

## How It Works

1. **Collect keys** — iterate parents and gather unique FK/PK values
2. **Batch query** — `SELECT * FROM children WHERE fk IN ($1, $2, ...)`
3. **Load & map** — convert rows to typed objects, index by key
4. **Return** — a `Table` for manual wiring

This guarantees **exactly 2 queries** regardless of collection size.
