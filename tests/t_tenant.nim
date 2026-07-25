## Тестове за Multi-tenant support (schema_prefix + tenant_id)

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

necto_schema TenantDoc:
  table "test_tenant_docs"
  tenant_id
  field id: int64 {.primary_key, auto_increment.}
  field tenant_id: string {.not_null.}
  field title: string {.not_null.}

necto_schema OrgDoc:
  table "test_org_docs"
  tenant_id "organization_id"
  field id: int64 {.primary_key, auto_increment.}
  field organization_id: string {.not_null.}
  field title: string {.not_null.}

suite "Multi-tenant (schema_prefix)":
  setup:
    testrepoInstance.clearTenantScope()
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_users")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_noprefix")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_docs")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_org_docs")
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
    testrepoInstance.exec("""
      CREATE TABLE test_tenant_docs (
        id BIGSERIAL PRIMARY KEY,
        tenant_id TEXT NOT NULL,
        title TEXT NOT NULL
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_org_docs (
        id BIGSERIAL PRIMARY KEY,
        organization_id TEXT NOT NULL,
        title TEXT NOT NULL
      )
    """)

  teardown:
    testrepoInstance.clearTenantScope()
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_users")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_noprefix")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_docs")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_org_docs")

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

suite "Multi-tenant (tenant_id row-level)":
  setup:
    testrepoInstance.clearTenantScope()
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_docs")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_org_docs")
    testrepoInstance.exec("""
      CREATE TABLE test_tenant_docs (
        id BIGSERIAL PRIMARY KEY,
        tenant_id TEXT NOT NULL,
        title TEXT NOT NULL
      )
    """)
    testrepoInstance.exec("""
      CREATE TABLE test_org_docs (
        id BIGSERIAL PRIMARY KEY,
        organization_id TEXT NOT NULL,
        title TEXT NOT NULL
      )
    """)

  teardown:
    testrepoInstance.clearTenantScope()
    testrepoInstance.exec("DROP TABLE IF EXISTS test_tenant_docs")
    testrepoInstance.exec("DROP TABLE IF EXISTS test_org_docs")

  test "schema meta has tenantIdColumn":
    check(schemaMeta(TenantDoc).tenantIdColumn == "tenant_id")
    check(schemaMeta(OrgDoc).tenantIdColumn == "organization_id")
    check(schemaMeta(NoPrefixUser).tenantIdColumn.len == 0)

  test "auto WHERE tenant_id when setTenantId":
    testrepoInstance.setTenantId("acme")
    let bq = fromSchema(TenantDoc).toBoundQuery()
    check(bq.sql.contains("\"tenant_id\" = $"))
    check(bq.args.contains("acme"))
    testrepoInstance.clearTenantId()

  test "withoutTenant skips filter":
    testrepoInstance.setTenantId("acme")
    let bq = fromSchema(TenantDoc).withoutTenant().toBoundQuery()
    check(not bq.sql.contains("\"tenant_id\" = $"))
    testrepoInstance.clearTenantId()

  test "insert auto-injects tenant_id":
    testrepoInstance.setTenantId("acme")
    var cs = newChangeset(newTenantDoc(), {"title": "Doc A"}.toTable)
      .castFields(@["title"])
    let doc = testrepoInstance.insert(cs)
    check(doc.id > 0)
    check(doc.tenant_id == "acme")
    check(doc.title == "Doc A")
    testrepoInstance.clearTenantId()

  test "queries isolate tenants":
    # seed two tenants without scope (raw insert with explicit tenant_id)
    var a = newChangeset(newTenantDoc(), {"tenant_id": "acme", "title": "A1"}.toTable)
      .castFields(@["tenant_id", "title"])
    var b = newChangeset(newTenantDoc(), {"tenant_id": "globex", "title": "G1"}.toTable)
      .castFields(@["tenant_id", "title"])
    discard testrepoInstance.insert(a)
    discard testrepoInstance.insert(b)

    testrepoInstance.setTenantId("acme")
    let acmeDocs = testrepoInstance.all(fromSchema(TenantDoc))
    check(acmeDocs.len == 1)
    check(acmeDocs[0].title == "A1")

    testrepoInstance.setTenantId("globex")
    let globexDocs = testrepoInstance.all(fromSchema(TenantDoc))
    check(globexDocs.len == 1)
    check(globexDocs[0].title == "G1")

    testrepoInstance.clearTenantId()
    # without tenant id, no auto filter
    check(testrepoInstance.all(fromSchema(TenantDoc)).len == 2)

  test "custom tenant column name":
    testrepoInstance.setTenantId("org-9")
    let bq = fromSchema(OrgDoc).toBoundQuery()
    check(bq.sql.contains("\"organization_id\" = $"))
    check(bq.args.contains("org-9"))

    var cs = newChangeset(newOrgDoc(), {"title": "Report"}.toTable)
      .castFields(@["title"])
    let doc = testrepoInstance.insert(cs)
    check(doc.organization_id == "org-9")
    testrepoInstance.clearTenantId()
