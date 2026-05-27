## Интеграционен тест: Асоциации и Preload

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Schemas ---
# Post е дефиниран преди User за да avoid-нем forward reference (User има has_many posts: Post)
necto_schema Profile:
  table "test_profiles_assoc"
  field id: int64 {.primary_key, auto_increment.}
  field bio: string
  field user_id: int64
  timestamps

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
  has_one profile: Profile

suite "Associations and Preload":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_posts_assoc\"")
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_profiles_assoc\"")
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
    testrepoInstance.exec("""
      CREATE TABLE "test_profiles_assoc" (
        id BIGSERIAL PRIMARY KEY,
        bio TEXT,
        user_id BIGINT REFERENCES "test_users_assoc"(id),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_posts_assoc\"")
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_profiles_assoc\"")
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_users_assoc\"")

  test "Schema associations metadata is correct":
    let userMeta = schemaMeta(User)
    check(userMeta.associations.len == 2)
    check(userMeta.associations[0].name == "posts")
    check(userMeta.associations[0].kind == akHasMany)
    check(userMeta.associations[0].targetSchema == "Post")
    check(userMeta.associations[1].name == "profile")
    check(userMeta.associations[1].kind == akHasOne)
    check(userMeta.associations[1].targetSchema == "Profile")

    let postMeta = schemaMeta(Post)
    check(postMeta.associations.len == 1)
    check(postMeta.associations[0].name == "author")
    check(postMeta.associations[0].kind == akBelongsTo)
    check(postMeta.associations[0].targetSchema == "User")

    let profileMeta = schemaMeta(Profile)
    check(profileMeta.associations.len == 0)

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

  test "allWithPreload automatically loads belongs_to":
    # Seed
    var userCs = newChangeset(newUser(), {"name": "AutoAuthor"}.toTable)
    userCs = userCs.castFields(@["name"])
    let author = testrepoInstance.insert(userCs)

    for i in 1..2:
      var pCs = newChangeset(newPost(), {"title": "Auto Post " & $i, "author_id": $author.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    let posts = testrepoInstance.allWithPreload(
      fromSchema(Post).orderBy("id", Asc),
      "author"
    )
    check(posts.len == 2)
    check(posts[0].author.name == "AutoAuthor")
    check(posts[1].author.name == "AutoAuthor")

  test "allWithPreload automatically loads has_many":
    # Seed
    var userCs = newChangeset(newUser(), {"name": "MultiPost"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u = testrepoInstance.insert(userCs)

    for i in 1..3:
      var pCs = newChangeset(newPost(), {"title": "MP " & $i, "author_id": $u.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    let users = testrepoInstance.allWithPreload(
      fromSchema(User).where("name", Eq, "MultiPost"),
      "posts"
    )
    check(users.len == 1)
    check(users[0].posts.len == 3)
    check(users[0].posts[0].title == "MP 1")

  test "HasOne preload returns profile by user_id":
    # Seed
    var userCs = newChangeset(newUser(), {"name": "ProfileUser"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u = testrepoInstance.insert(userCs)

    var profCs = newChangeset(newProfile(), {"bio": "Hello world", "user_id": $u.id}.toTable)
    profCs = profCs.castFields(@["bio", "user_id"])
    discard testrepoInstance.insert(profCs)

    let users = testrepoInstance.all(fromSchema(User).orderBy("id", Asc))
    check(users.len == 1)

    let profiles = preloadHasOne[User, Profile](testrepoInstance, users)
    check(profiles[users[0].id].bio == "Hello world")

  test "allWithPreload automatically loads has_one":
    var userCs = newChangeset(newUser(), {"name": "AutoProfile"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u = testrepoInstance.insert(userCs)

    var profCs = newChangeset(newProfile(), {"bio": "Auto bio", "user_id": $u.id}.toTable)
    profCs = profCs.castFields(@["bio", "user_id"])
    discard testrepoInstance.insert(profCs)

    let users = testrepoInstance.allWithPreload(
      fromSchema(User).where("name", Eq, "AutoProfile"),
      "profile"
    )
    check(users.len == 1)
    check(users[0].profile.bio == "Auto bio")

  test "Query preload automatically loads belongs_to via repo.all":
    var userCs = newChangeset(newUser(), {"name": "QueryAuthor"}.toTable)
    userCs = userCs.castFields(@["name"])
    let author = testrepoInstance.insert(userCs)

    for i in 1..2:
      var pCs = newChangeset(newPost(), {"title": "QPost " & $i, "author_id": $author.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    let posts = testrepoInstance.all(
      fromSchema(Post).orderBy("id", Asc).preload("author")
    )
    check(posts.len == 2)
    check(posts[0].author.name == "QueryAuthor")
    check(posts[1].author.name == "QueryAuthor")

  test "Query preload automatically loads has_many via repo.all":
    var userCs = newChangeset(newUser(), {"name": "QueryMulti"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u = testrepoInstance.insert(userCs)

    for i in 1..3:
      var pCs = newChangeset(newPost(), {"title": "QP " & $i, "author_id": $u.id}.toTable)
      pCs = pCs.castFields(@["title", "author_id"])
      discard testrepoInstance.insert(pCs)

    let users = testrepoInstance.all(
      fromSchema(User).where("name", Eq, "QueryMulti").preload("posts")
    )
    check(users.len == 1)
    check(users[0].posts.len == 3)
    check(users[0].posts[0].title == "QP 1")

  test "Query preload automatically loads has_one via repo.all":
    var userCs = newChangeset(newUser(), {"name": "QueryProfile"}.toTable)
    userCs = userCs.castFields(@["name"])
    let u = testrepoInstance.insert(userCs)

    var profCs = newChangeset(newProfile(), {"bio": "Query bio", "user_id": $u.id}.toTable)
    profCs = profCs.castFields(@["bio", "user_id"])
    discard testrepoInstance.insert(profCs)

    let users = testrepoInstance.all(
      fromSchema(User).where("name", Eq, "QueryProfile").preload("profile")
    )
    check(users.len == 1)
    check(users[0].profile.bio == "Query bio")

  test "Query preload works via repo.one":
    var userCs = newChangeset(newUser(), {"name": "OneAuthor"}.toTable)
    userCs = userCs.castFields(@["name"])
    let author = testrepoInstance.insert(userCs)

    var pCs = newChangeset(newPost(), {"title": "OnePost", "author_id": $author.id}.toTable)
    pCs = pCs.castFields(@["title", "author_id"])
    discard testrepoInstance.insert(pCs)

    let maybePost = testrepoInstance.one(
      fromSchema(Post).where("title", Eq, "OnePost").preload("author")
    )
    check(maybePost.isSome)
    check(maybePost.get.author.name == "OneAuthor")

  test "build_assoc creates child with foreign key pre-filled":
    var userCs = newChangeset(newUser(), {"name": "Builder"}.toTable)
    userCs = userCs.castFields(@["name"])
    let user = testrepoInstance.insert(userCs)

    var postCs = build_assoc(user, Post, {"title": "Built Post", "body": "Built body"}.toTable)
    postCs = postCs.castFields(@["title", "body", "author_id"])
    check(postCs.isValid)
    check(postCs.data.author_id == user.id)

    let post = testrepoInstance.insert(postCs)
    check(post.title == "Built Post")
    check(post.author_id == user.id)

  test "build_assoc works for has_one associations":
    var userCs = newChangeset(newUser(), {"name": "ProfileBuilder"}.toTable)
    userCs = userCs.castFields(@["name"])
    let user = testrepoInstance.insert(userCs)

    var profCs = build_assoc(user, Profile, {"bio": "Built bio"}.toTable)
    profCs = profCs.castFields(@["bio", "user_id"])
    check(profCs.isValid)
    check(profCs.data.user_id == user.id)

    let prof = testrepoInstance.insert(profCs)
    check(prof.bio == "Built bio")
    check(prof.user_id == user.id)

  test "build_assoc with explicit assocName finds correct FK":
    var userCs = newChangeset(newUser(), {"name": "NamedBuilder"}.toTable)
    userCs = userCs.castFields(@["name"])
    let user = testrepoInstance.insert(userCs)

    # Explicit assocName "posts" should resolve correctly
    var postCs = build_assoc(user, Post, {"title": "Named Post"}.toTable, "posts")
    postCs = postCs.castFields(@["title", "author_id"])
    check(postCs.isValid)
    check(postCs.data.author_id == user.id)

    let post = testrepoInstance.insert(postCs)
    check(post.title == "Named Post")
    check(post.author_id == user.id)

  test "oneWithPreload loads has_one association":
    var userCs = newChangeset(newUser(), {"name": "OneProfile"}.toTable)
    userCs = userCs.castFields(@["name"])
    let user = testrepoInstance.insert(userCs)

    var profCs = newChangeset(newProfile(), {"bio": "One bio", "user_id": $user.id}.toTable)
    profCs = profCs.castFields(@["bio", "user_id"])
    discard testrepoInstance.insert(profCs)

    let maybeUser = testrepoInstance.oneWithPreload(
      fromSchema(User).where("name", Eq, "OneProfile"), "profile"
    )
    check(maybeUser.isSome)
    check(maybeUser.get.profile.bio == "One bio")

  test "oneWithPreload loads belongs_to association":
    var userCs = newChangeset(newUser(), {"name": "OneAuthor2"}.toTable)
    userCs = userCs.castFields(@["name"])
    let author = testrepoInstance.insert(userCs)

    var pCs = newChangeset(newPost(), {"title": "OnePost2", "author_id": $author.id}.toTable)
    pCs = pCs.castFields(@["title", "author_id"])
    discard testrepoInstance.insert(pCs)

    let maybePost = testrepoInstance.oneWithPreload(
      fromSchema(Post).where("title", Eq, "OnePost2"), "author"
    )
    check(maybePost.isSome)
    check(maybePost.get.author.name == "OneAuthor2")
