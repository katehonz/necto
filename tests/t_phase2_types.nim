## Тест за типовете от Фаза 2
## PostgreSQL масиви, bytea, enum, decimal

import std/[unittest, tables, options, json]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Enums ---

type
  Status* = enum Draft, Published, Archived
  Priority* = enum Low, Normal, High

# --- Schema с всички Фаза 2 типове ---

necto_schema Article:
  table "test_articles_phase2"
  field id: int64 {.primary_key, auto_increment.}
  field title: string {.not_null.}
  field tags: seq[string]
  field ratings: seq[int]
  field status: Status
  field priority: Priority
  field price: Decimal
  field checksum: seq[byte]
  timestamps

suite "Phase 2 types: arrays, bytea, enum, decimal":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_articles_phase2\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_articles_phase2" (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        tags TEXT[],
        ratings INTEGER[],
        status TEXT,
        priority TEXT,
        price NUMERIC,
        checksum BYTEA,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_articles_phase2\"")

  test "Insert and load array fields":
    var cs = newChangeset(newArticle(), {
      "title": "Nim Tutorial",
      "tags": "{nim,programming,tutorial}",
      "ratings": "{5,4,5}",
      "status": "Published",
      "priority": "High",
      "price": "19.99",
      "checksum": "\\xDEADBEEF"
    }.toTable)
    cs = cs.castFields(@["title", "tags", "ratings", "status", "priority", "price", "checksum"])
    check(cs.isValid)

    let a = testrepoInstance.insert(cs)
    check(a.title == "Nim Tutorial")
    check(a.tags == @["nim", "programming", "tutorial"])
    check(a.ratings == @[5, 4, 5])
    check(a.status == Published)
    check(a.priority == High)
    check(a.price == Decimal("19.99"))
    check(a.checksum == @[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])

  test "Query with array and enum fields":
    var cs1 = newChangeset(newArticle(), {
      "title": "Article One",
      "tags": "{news}",
      "ratings": "{3}",
      "status": "Draft",
      "priority": "Low",
      "price": "9.99",
      "checksum": "\\x00"
    }.toTable)
    cs1 = cs1.castFields(@["title", "tags", "ratings", "status", "priority", "price", "checksum"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newArticle(), {
      "title": "Article Two",
      "tags": "{tech,review}",
      "ratings": "{5,5}",
      "status": "Published",
      "priority": "Normal",
      "price": "29.99",
      "checksum": "\\xFFAA"
    }.toTable)
    cs2 = cs2.castFields(@["title", "tags", "ratings", "status", "priority", "price", "checksum"])
    discard testrepoInstance.insert(cs2)

    let articles = testrepoInstance.all(fromSchema(Article).orderBy("id", Asc))
    check(articles.len == 2)
    check(articles[0].title == "Article One")
    check(articles[0].tags == @["news"])
    check(articles[0].ratings == @[3])
    check(articles[0].status == Draft)
    check(articles[0].priority == Low)
    check(articles[1].title == "Article Two")
    check(articles[1].tags == @["tech", "review"])
    check(articles[1].ratings == @[5, 5])
    check(articles[1].status == Published)
    check(articles[1].priority == Normal)

  test "Type system roundtrip — arrays":
    let tags = loadValue("{hello,world}", seq[string])
    check(tags == @["hello", "world"])
    check(dumpValue(@["hello", "world"]) == "{hello,world}")

    let nums = loadValue("{10,20,30}", seq[int])
    check(nums == @[10, 20, 30])
    check(dumpValue(@[10, 20, 30]) == "{10,20,30}")

    let empty = loadValue("{}", seq[string])
    check(empty.len == 0)
    check(dumpValue(newSeq[string]()) == "{}")

  test "Type system roundtrip — array with special chars":
    let tags = loadValue("{\"hello, world\",\"a\\\"b\"}", seq[string])
    check(tags == @["hello, world", "a\"b"])
    check(dumpValue(@["hello, world", "a\"b"]) == "{\"hello, world\",\"a\\\"b\"}")

  test "Type system roundtrip — bytea":
    let data = loadValue("\\xDEADBEEF", seq[byte])
    check(data == @[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])
    check(dumpValue(@[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8]) == "\\xdeadbeef")

    let empty = loadValue("\\x", seq[byte])
    check(empty.len == 0)

  test "Type system roundtrip — enum":
    let s = loadValue("Published", Status)
    check(s == Published)
    check(dumpValue(Published) == "Published")

    let s2 = loadValue("0", Status)
    check(s2 == Draft)

  test "Type system roundtrip — decimal":
    let d = loadValue("123.456", Decimal)
    check(d == Decimal("123.456"))
    check(dumpValue(Decimal("123.456")) == "123.456")

    let d0 = loadValue("", Decimal)
    check(d0 == Decimal("0"))

  test "Empty arrays and nulls":
    var cs = newChangeset(newArticle(), {
      "title": "Minimal",
      "tags": "{}",
      "ratings": "{}",
      "status": "Draft",
      "priority": "Low",
      "price": "0.00",
      "checksum": "\\x"
    }.toTable)
    cs = cs.castFields(@["title", "tags", "ratings", "status", "priority", "price", "checksum"])
    let a = testrepoInstance.insert(cs)
    check(a.tags.len == 0)
    check(a.ratings.len == 0)
    check(a.checksum.len == 0)
