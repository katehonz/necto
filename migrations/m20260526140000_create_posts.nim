## Примерна миграция: CreatePosts
import necto
import necto/migration

necto_migration CreatePosts, "20260526130000":
  up:
    createTable repo, "posts", [
      pk("id"),
      col("title", "text", nullable = false),
      col("body", "text"),
      col("author_id", "bigint", reference = "users(id)"),
      timestamps()
    ]
    createIndex repo, "posts", @["author_id"]

  down:
    dropTable repo, "posts"
