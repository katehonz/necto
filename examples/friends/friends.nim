# Friends example — Necto getting started
#
# Демонстрира основната функционалност на Necto:
#   - Дефиниране на Repo
#   - Дефиниране на Schema (User, Post, Comment)
#   - CRUD операции
#   - Query строител
#   - Changeset валидации
#   - Асоциации

import std/[tables, options]
import necto
import necto/adapters/postgres

# --- Repo дефиниция ---

necto_repo FriendsRepo:
  adapter PostgresAdapter
  host "localhost"
  port 5432
  user "postgres"
  password "pas+123"
  database "necto_friends"
  pool_size 5

# --- Schema дефиниции ---

necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  field name: string
  field email: string
  field age: int
  timestamps

necto_schema Post:
  table "posts"
  field id: int64 {.primary_key.}
  field title: string
  field body: string
  belongs_to author: User
  timestamps

necto_schema Comment:
  table "comments"
  field id: int64 {.primary_key.}
  field body: string
  belongs_to post: Post
  belongs_to author: User
  timestamps

# Удобен alias
let repo = friendsrepoInstance

# --- Seed данни ---

proc seed() =
  echo "=== Seeding data ==="

  # Създаване на таблици
  repo.transaction proc() =
    repo.exec("""
      CREATE TABLE IF NOT EXISTS users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        age INTEGER,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

    repo.exec("""
      CREATE TABLE IF NOT EXISTS posts (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT,
        author_id BIGINT REFERENCES users(id),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

    repo.exec("""
      CREATE TABLE IF NOT EXISTS comments (
        id BIGSERIAL PRIMARY KEY,
        body TEXT,
        post_id BIGINT REFERENCES posts(id),
        author_id BIGINT REFERENCES users(id),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  echo "Tables created."

# --- Демонстрация на CRUD ---

proc demo() =
  echo "\n=== Demo: CRUD operations ==="

  # 1. INSERT чрез raw SQL
  repo.exec("""
    INSERT INTO users (name, email, age) VALUES ('Ivan', 'ivan@test.com', 30)
  """)

  # 2. SELECT all
  let query = fromSchema(User)
  let users = repo.all(query)
  echo "Users: ", users.len

  # 3. INSERT чрез Changeset
  let params1 = {"name": "Maria", "email": "maria@test.com", "age": "25"}.toTable
  var cs1 = newChangeset(newUser(), params1)
  cs1 = cs1.castFields(@["name", "email", "age"])
  cs1 = cs1.validateRequired(@["name"])
  cs1.action = "insert"

  let user2 = repo.insert(cs1)
  echo "Inserted user: ", user2.name, " (", user2.email, ")"

  # 4. SELECT one
  let query2 = fromSchema(User).where("name", Eq, "Maria")
  let maybeUser = repo.one(query2)
  if maybeUser.isSome():
    echo "Found: ", maybeUser.get().name

  # 5. COUNT
  let total = repo.count(fromSchema(User))
  echo "Total users: ", total

  # 6. UPDATE
  var cs2 = newChangeset(user2, {"name": "Maria Updated"}.toTable)
  cs2 = cs2.castFields(@["name"])
  cs2.action = "update"
  cs2.changes["id"] = "2"  # PK за WHERE клауза
  let updatedUser = repo.update(cs2)
  echo "Updated user: ", updatedUser.name

  # 7. DELETE
  var cs3 = newChangeset(updatedUser, initTable[string, string]())
  cs3.changes["id"] = "2"
  cs3.action = "delete"
  let deletedUser = repo.delete(cs3)
  echo "Deleted user with id: ", deletedUser.id

  echo "\n=== Demo complete ==="

# --- Стартиране ---

when isMainModule:
  echo "Necto Friends Example"
  echo "====================="

  try:
    seed()
    demo()
  except DatabaseError as e:
    echo "Database error: ", e.msg
  except ValidationError as e:
    echo "Validation error: ", e.msg
  except NectoError as e:
    echo "Necto error: ", e.msg
