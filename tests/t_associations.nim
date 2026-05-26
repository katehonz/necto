## Интеграционен тест: Асоциации и Preload

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Schemas ---
# Post е дефиниран преди User за да avoid-нем forward reference (User има has_many posts: Post)
necto_schema Post:
  table "test_posts_assoc"
  field id: int64 {.primary_key, auto_increment.}
  field title: string {.not_null.}
  field body: string
  belongs_to author: User
  timestamps

necto_schema User:
  table "test_users_assoc"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  timestamps
  has_many posts: Post

suite "Associations and Preload":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_posts_assoc\"")
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_users_assoc\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_users_assoc" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE "test_posts_assoc" (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT,
        author_id BIGINT REFERENCES "test_users_assoc"(id),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_posts_assoc\"")
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_users_assoc\"")

  test "Schema associations metadata is correct":
    let userMeta = schemaMeta(User)
    check(userMeta.associations.len == 1)
    check(userMeta.associations[0].name == "posts")
    check(userMeta.associations[0].kind == akHasMany)
    check(userMeta.associations[0].targetSchema == "Post")

    let postMeta = schemaMeta(Post)
    check(postMeta.associations.len == 1)
    check(postMeta.associations[0].name == "author")
    check(postMeta.associations[0].kind == akBelongsTo)
    check(postMeta.associations[0].targetSchema == "User")

  test "Insert users and posts via changeset":
    var userCs = newChangeset(newUser(), {"name": "Ivan", "email": "ivan@test.com"}.toTable)
    userCs = userCs.castFields(@["name", "email"])
    let user = testrepoInstance.insert(userCs)
    check(user.id > 0)

    var postCs = newChangeset(newPost(), {"title": "Hello", "body": "World", "author_id": $user.id}.toTable)
    postCs = postCs.castFields(@["title", "body", "author_id"])
    let post = testrepoInstance.insert(postCs)
    check(post.id > 0)
    check(post.author_id == user.id)

  test "BelongsTo preload returns authors by id":
    # Seed
    var userCs = newChangeset(newUser(), {"name": "Author1"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u1 = testrepoInstance.insert(userCs)

    var userCs2 = newChangeset(newUser(), {"name": "Author2"}.toTable)
    userCs2 = userCs2.castFields(@["name"])
    let u2 = testrepoInstance.insert(userCs2)

    for i in 1..3:
      var pCs = newChangeset(newPost(), {"title": "Post " & $i, "author_id": $(if i == 3: u2.id else: u1.id)}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    # Load posts
    let posts = testrepoInstance.all(fromSchema(Post).orderBy("id", Asc))
    check(posts.len == 3)

    # Preload authors
    let authors = preloadBelongsTo[Post, User](testrepoInstance, posts)

    check(authors.len == 2)
    check(authors[posts[0].author_id].name == "Author1")
    check(authors[posts[1].author_id].name == "Author1")
    check(authors[posts[2].author_id].name == "Author2")

  test "HasMany preload returns posts by author_id":
    # Seed
    var userCs = newChangeset(newUser(), {"name": "Alice"}.toTable)
    userCs = userCs.castFields(@["name"])
    let alice = testrepoInstance.insert(userCs)

    var userCs2 = newChangeset(newUser(), {"name": "Bob"}.toTable)
    userCs2 = userCs2.castFields(@["name"])
    let bob = testrepoInstance.insert(userCs2)

    for i in 1..2:
      var pCs = newChangeset(newPost(), {"title": "Alice Post " & $i, "author_id": $alice.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    for i in 1..3:
      var pCs = newChangeset(newPost(), {"title": "Bob Post " & $i, "author_id": $bob.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    # Load users
    let users = testrepoInstance.all(fromSchema(User).orderBy("id", Asc))
    check(users.len == 2)

    # Preload posts
    let userPosts = preloadHasMany[User, Post](testrepoInstance, users)

    check(userPosts[users[0].id].len == 2)
    check(userPosts[users[1].id].len == 3)
    check(userPosts[users[0].id][0].title == "Alice Post 1")
    check(userPosts[users[1].id][0].title == "Bob Post 1")
