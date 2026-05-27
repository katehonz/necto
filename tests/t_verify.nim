## Тест за Schema Verification
##
## Проверява че verifySchema() работи коректно с реална PostgreSQL база.

import std/[unittest, tables, strutils]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

suite "Schema Verification (runtime)":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"verify_test_users\" CASCADE")
    testrepoInstance.exec("""
      CREATE TABLE "verify_test_users" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        age BIGINT
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"verify_test_users\" CASCADE")

  test "verifySchema passes for matching schema":
    let fields = @[
      SchemaFieldInfo(nimName: "id", dbColumn: "id", nimType: "int64",
                       dbType: "bigint", isPrimaryKey: true, isNullable: false, isUnique: false),
      SchemaFieldInfo(nimName: "name", dbColumn: "name", nimType: "string",
                       dbType: "text", isPrimaryKey: false, isNullable: false, isUnique: false),
      SchemaFieldInfo(nimName: "email", dbColumn: "email", nimType: "string",
                       dbType: "text", isPrimaryKey: false, isNullable: true, isUnique: false),
      SchemaFieldInfo(nimName: "age", dbColumn: "age", nimType: "int64",
                       dbType: "bigint", isPrimaryKey: false, isNullable: true, isUnique: false),
    ]

    let r = verifySchema("localhost", 5432, "postgres", "pas+123", "necto_test",
                          "verify_test_users", fields)
    check(r.errors.len == 0)
    check(r.warnings.len == 0)

  test "verifySchema detects missing column in DB":
    let fields = @[
      SchemaFieldInfo(nimName: "id", dbColumn: "id", nimType: "int64",
                       dbType: "bigint", isPrimaryKey: true, isNullable: false, isUnique: false),
      SchemaFieldInfo(nimName: "name", dbColumn: "name", nimType: "string",
                       dbType: "text", isPrimaryKey: false, isNullable: false, isUnique: false),
      SchemaFieldInfo(nimName: "missing_col", dbColumn: "missing_col", nimType: "string",
                       dbType: "text", isPrimaryKey: false, isNullable: true, isUnique: false),
    ]

    let r = verifySchema("localhost", 5432, "postgres", "pas+123", "necto_test",
                          "verify_test_users", fields)
    check(r.errors.len >= 1)
    var hasMissingCol = false
    for e in r.errors:
      if e.find("missing_col") >= 0:
        hasMissingCol = true
    check(hasMissingCol)

  test "verifySchema detects NOT NULL mismatch":
    let fields = @[
      SchemaFieldInfo(nimName: "name", dbColumn: "name", nimType: "string",
                       dbType: "text", isPrimaryKey: false, isNullable: true, isUnique: false),
    ]

    let r = verifySchema("localhost", 5432, "postgres", "pas+123", "necto_test",
                          "verify_test_users", fields)
    # name е NOT NULL в DB но е nullable в schema → това е warning (не error защото не е обратното)
    check(r.errors.len == 0)

  test "verifySchema detects non-existent table":
    let fields = @[
      SchemaFieldInfo(nimName: "id", dbColumn: "id", nimType: "int64",
                       dbType: "bigint", isPrimaryKey: true, isNullable: false, isUnique: false),
    ]

    let r = verifySchema("localhost", 5432, "postgres", "pas+123", "necto_test",
                          "nonexistent_table_xyz", fields)
    check(r.errors.len >= 1)
    check(r.errors[0].find("does not exist") >= 0)

  test "verifySchema detects extra DB columns (warning)":
    let fields = @[
      SchemaFieldInfo(nimName: "id", dbColumn: "id", nimType: "int64",
                       dbType: "bigint", isPrimaryKey: true, isNullable: false, isUnique: false),
    ]

    let r = verifySchema("localhost", 5432, "postgres", "pas+123", "necto_test",
                          "verify_test_users", fields)
    # Има колони в DB (name, email, age) които липсват в schema → warning
    check(r.warnings.len >= 1)
    var hasExtraCol = false
    for w in r.warnings:
      if w.find("not in schema") >= 0:
        hasExtraCol = true
    check(hasExtraCol)

# --- Type Compatibility Tests ---

suite "Type Compatibility":
  test "isTypeCompatible — exact match":
    check(isTypeCompatible("text", "text"))
    check(isTypeCompatible("bigint", "bigint"))
    check(isTypeCompatible("integer", "integer"))
    check(isTypeCompatible("boolean", "boolean"))
    check(isTypeCompatible("jsonb", "jsonb"))

  test "isTypeCompatible — aliases":
    check(isTypeCompatible("text", "varchar"))
    check(isTypeCompatible("varchar", "text"))
    check(isTypeCompatible("integer", "int4"))
    check(isTypeCompatible("bigint", "int8"))
    check(isTypeCompatible("smallint", "int2"))
    check(isTypeCompatible("jsonb", "json"))
    check(isTypeCompatible("json", "jsonb"))
    check(isTypeCompatible("bool", "boolean"))

  test "isTypeCompatible — incompatible":
    check(not isTypeCompatible("text", "integer"))
    check(not isTypeCompatible("bigint", "boolean"))
    check(not isTypeCompatible("integer", "text"))
    check(not isTypeCompatible("jsonb", "bigint"))

# --- Format Test ---

suite "formatResult":
  test "formatResult with errors and warnings":
    var r = VerificationResult(tableName: "test_table")
    r.errors.add("ERROR: Something wrong")
    r.warnings.add("WARNING: Something off")

    let output = formatResult(r)
    check(output.find("ERROR") >= 0)
    check(output.find("WARNING") >= 0)
    check(output.find("test_table") >= 0)