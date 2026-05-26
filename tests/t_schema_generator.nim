## Тест за Schema Generator (reverse engineering)

import std/[unittest, strutils]
import ../src/necto
import ../src/necto/schema_generator
import db_connector/db_postgres
import support/test_repo

suite "Schema Generator":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"gen_test_table\"")
    testrepoInstance.exec("""
      CREATE TABLE "gen_test_table" (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT,
        view_count INTEGER DEFAULT 0,
        is_published BOOLEAN DEFAULT false,
        settings JSONB,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"gen_test_table\"")

  test "inspectTable reads correct column info":
    # Използваме директна връзка за schema_generator
    let conn = open("127.0.0.1:5432", "postgres", "pas+123", "necto_test")
    defer: close(conn)

    let info = inspectTable(conn, "gen_test_table")
    check(info.name == "gen_test_table")
    check(info.columns.len == 8)
    check(info.hasTimestamps == true)

    let idCol = info.columns[0]
    check(idCol.name == "id")
    check(idCol.pgType == "bigint")
    check(idCol.isPrimaryKey == true)
    check(idCol.isNullable == false)

    let titleCol = info.columns[1]
    check(titleCol.name == "title")
    check(titleCol.pgType == "text")
    check(titleCol.isNullable == false)

    let bodyCol = info.columns[2]
    check(bodyCol.name == "body")
    check(bodyCol.isNullable == true)

    let settingsCol = info.columns[5]
    check(settingsCol.name == "settings")
    check(settingsCol.pgType == "jsonb")

  test "generateSchema produces valid Nim code":
    let conn = open("127.0.0.1:5432", "postgres", "pas+123", "necto_test")
    defer: close(conn)

    let info = inspectTable(conn, "gen_test_table")
    let code = generateSchema(info, schemaName = "GenTest")

    check(code.contains("necto_schema GenTest:"))
    check(code.contains("table \"gen_test_table\""))
    check(code.contains("field id: int64 {primary_key, auto_increment}"))
    check(code.contains("field title: string {not_null}"))
    check(code.contains("field body: Option[string]"))
    check(code.contains("field view_count: Option[int]"))
    check(code.contains("field is_published: Option[bool]"))
    check(code.contains("field settings: JsonNode"))
    check(code.contains("timestamps"))
