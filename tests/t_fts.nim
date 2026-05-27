## Тестове за Full-Text Search (FTS) DSL

import std/[unittest, tables, options, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema FtsArticle:
  table "test_fts_articles"
  field id: int64 {.primary_key, auto_increment.}
  field title: string {.not_null.}
  field body: string
  field search_vector: string

suite "Full-Text Search":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_fts_articles")
    testrepoInstance.exec("""
      CREATE TABLE test_fts_articles (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT,
        search_vector TSVECTOR
      )
    """)
    # Insert articles with precomputed search_vector
    testrepoInstance.exec("""
      INSERT INTO test_fts_articles (title, body, search_vector)
      VALUES ('Nim ORM Guide', 'A guide to Nim ORMs and databases',
              to_tsvector('simple', 'Nim ORM Guide A guide to Nim ORMs and databases'))
    """)
    testrepoInstance.exec("""
      INSERT INTO test_fts_articles (title, body, search_vector)
      VALUES ('Python Web Framework', 'Django and Flask comparison',
              to_tsvector('simple', 'Python Web Framework Django and Flask comparison'))
    """)
    testrepoInstance.exec("""
      INSERT INTO test_fts_articles (title, body, search_vector)
      VALUES ('Nim Tutorial', 'Learning Nim programming language',
              to_tsvector('simple', 'Nim Tutorial Learning Nim programming language'))
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_fts_articles")

  test "whereTsVectorMatches with plaintoTsQuery":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim"))
    let bq = q.toBoundQuery()
    check("\"search_vector\" @@ plainto_tsquery('simple', $1)" in bq.sql)
    check(bq.args == @["nim"])

    let results = testrepoInstance.all(q)
    check(results.len == 2)  # "Nim ORM Guide" and "Nim Tutorial"

  test "whereTsVectorMatches with phrasetoTsQuery":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", phrasetoTsQuery("simple", "nim orm"))
    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].title == "Nim ORM Guide")

  test "orWhereTsVectorMatches":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "django"))
      .orWhereTsVectorMatches("search_vector", plaintoTsQuery("simple", "flask"))
    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].title == "Python Web Framework")

  test "orderByTsRank":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim"))
      .orderByTsRank("search_vector", plaintoTsQuery("simple", "nim"), Desc)
    let bq = q.toBoundQuery()
    check("ORDER BY" in bq.sql)
    check("ts_rank" in bq.sql)
    check("DESC" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 2)
    # Both contain "nim"; order should be deterministic by rank
    check(results[0].title.contains("Nim"))
    check(results[1].title.contains("Nim"))

  test "orderByTsRankCd":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim"))
      .orderByTsRankCd("search_vector", plaintoTsQuery("simple", "nim"), Desc)
    let bq = q.toBoundQuery()
    check("ts_rank_cd" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 2)

  test "websearchToTsQuery":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", websearchToTsQuery("simple", "nim -django"))
    let bq = q.toBoundQuery()
    check("websearch_to_tsquery('simple', $1)" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 2)  # nim articles, excluding django

  test "toTsQuery with boolean operators":
    let q = fromSchema(FtsArticle)
      .whereTsVectorMatches("search_vector", toTsQuery("simple", "nim & tutorial"))
    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].title == "Nim Tutorial")

  test "combined where + fts + regular where":
    let q = fromSchema(FtsArticle)
      .where("title", Like, "%Nim%")
      .whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "programming"))
    let bq = q.toBoundQuery()
    check("\"title\" LIKE $1" in bq.sql)
    check("@@" in bq.sql)

    let results = testrepoInstance.all(q)
    check(results.len == 1)
    check(results[0].title == "Nim Tutorial")

  test "toTsVector template generates correct SQL":
    let vec = toTsVector("english", "title")
    check(vec == "to_tsvector('english', \"title\")")
