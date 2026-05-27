## Тестове за Multi-tenant support (schema_prefix)

import std/[unittest, os, strutils, tables, options]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema TenantUser:
  table "test_tenant_users"
  schema_prefix "public"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string

necto_schema NoPrefixUser:
  table "test_tenant_noprefix"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}

suite "Multi-tenant (schema_prefix)":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_users")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_noprefix")
    testrepoInstance.exec("""
      CREATE TABLE test_tenant_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_tenant_noprefix (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_users")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_noprefix")

  test "schema meta has schemaPrefix":
    let meta = schemaMeta(TenantUser)
    check(meta.schemaPrefix == "public")

  test "schema without prefix has empty schemaPrefix":
    let meta = schemaMeta(NoPrefixUser)
    check(meta.schemaPrefix.len == 0)

  test "schema with prefix generates qualified table name in SQL":
    let q = fromSchema(TenantUser)
    let bq = q.toBoundQuery()
    check(bq.sql.contains("\"public\".\"test_tenant_users\""))

  test "schema without prefix generates unqualified table name":
    let q = fromSchema(NoPrefixUser)
    let bq = q.toBoundQuery()
    check(not bq.sql.contains(".\"test_tenant_noprefix\""))

  test "runtime tenant overrides static schema prefix":
    testrepoInstance.setTenant("tenant_42")

    let q = fromSchema(TenantUser)
    let bq = q.toBoundQuery()
    check(bq.sql.contains("\"tenant_42\".\"test_tenant_users\""))

    testrepoInstance.clearTenant()

  test "runtime tenant works on schemas without static prefix":
    testrepoInstance.setTenant("tenant_99")

    let q = fromSchema(NoPrefixUser)
    let bq = q.toBoundQuery()
    check(bq.sql.contains("\"tenant_99\".\"test_tenant_noprefix\""))

    testrepoInstance.clearTenant()

  test "clearTenant removes runtime prefix":
    testrepoInstance.setTenant("temp_tenant")
    testrepoInstance.clearTenant()

    let q = fromSchema(TenantUser)
    let bq = q.toBoundQuery()
    check(bq.sql.contains("\"public\".\"test_tenant_users\""))
    check(not bq.sql.contains("temp_tenant"))

  test "insert and query with tenant prefix works":
    var ucs = newChangeset(newTenantUser(), {"name": "TestTenant", "email": "t@test.com"}.toTable)
      .castFields(@["name", "email"])
    let user = testrepoInstance.insert(ucs)
    check(user.id > 0)
    check(user.name == "TestTenant")

    let results = testrepoInstance.all(fromSchema(TenantUser).where("name", Eq, "TestTenant"))
    check(results.len == 1)
    check(results[0].name == "TestTenant")
