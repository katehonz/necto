## Necto Query Verifier
##
## Startup-time SQL validation via PostgreSQL EXPLAIN.
## Validates that queries reference real tables and columns.
##
## Usage:
##   import necto/query_verifier
##   let q = verifyQuery(User, fromSchema(User).where("age", Gt, "18"))
##
## When compiled with -d:nectoVerify, the query is EXPLAIN-ed against
## the database at startup. Invalid queries stop the program immediately.

import std/[os, strutils, tables, sets, json]
import db_connector/db_postgres as pg
import ./query
import ./schema

# --- Column extraction from Query ---

proc stripQuotes(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    s[1..^2]
  else:
    s

proc extractColumns*[T](q: Query[T]): seq[string] =
  result = @[]
  for s in q.selectFields:
    if s != "*": result.add(stripQuotes(s))
  for w in q.whereClauses:
    result.add(stripQuotes(w.field))
  for o in q.orderClauses:
    result.add(stripQuotes(o.field))
  for a in q.aggregates:
    if a.field != "*": result.add(stripQuotes(a.field))
  for g in q.groupByFields:
    result.add(stripQuotes(g))
  for h in q.havingClauses:
    result.add(stripQuotes(h.field))

# --- Verification result types ---

type
  QueryVerifyResult* = object
    tableName*: string
    boundSql*: string
    errors*: seq[string]
    warnings*: seq[string]

# --- Database verification ---

proc getDbConfig*(): tuple[host: string; port: int; user, password, database: string] =
  result.host = getEnv("PGHOST", "localhost")
  result.port = parseInt(getEnv("PGPORT", "5432"))
  result.user = getEnv("PGUSER", "postgres")
  result.password = getEnv("PGPASSWORD", "")
  result.database = getEnv("PGDATABASE", "necto_test")

proc verifyQueryAgainstDb*(host: string; port: int; user, password, database: string;
                            tableName: string; columns: seq[string];
                            boundSql: string): QueryVerifyResult =
  result = QueryVerifyResult(tableName: tableName, boundSql: boundSql)

  var db: pg.DbConn
  try:
    let connStr = host & ":" & $port
    db = pg.open(connStr, user, password, database)
  except:
    result.errors.add("Cannot connect to '" & database & "'")
    return
  defer: db.close()

  # Table exists?
  let existsRow = db.getRow(
    sql"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ?)",
    tableName)
  if existsRow.len == 0 or existsRow[0] != "t":
    result.errors.add("Table '" & tableName & "' does not exist")
    return

  # Columns exist?
  var dbCols: HashSet[string]
  for row in db.getAllRows(
    sql"SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ?",
    tableName):
    dbCols.incl(row[0])

  for col in columns:
    if col == "*": continue
    let clean = col.replace("\"", "")
    let short = if "." in clean: clean.split(".")[^1] else: clean
    if clean notin dbCols and short notin dbCols:
      result.errors.add("Column '" & col & "' not found in '" & tableName & "'")

  # EXPLAIN check
  if boundSql.len > 0:
    var safeSql = "EXPLAIN (FORMAT JSON) " & boundSql
    for i in 1..30:
      safeSql = safeSql.replace("$" & $i, "NULL")
    try:
      let explainRow = db.getRow(sql(safeSql))
      if explainRow.len > 0 and explainRow[0].len > 0:
        discard  # query is valid
    except:
      result.errors.add("SQL error: " & getCurrentExceptionMsg())

proc formatQueryResult*(r: QueryVerifyResult): string =
  if r.errors.len == 0 and r.warnings.len == 0: return ""
  result = "═══ QUERY VERIFY: " & r.tableName & " ═══\n"
  if r.boundSql.len > 0:
    result.add("  SQL: " & r.boundSql & "\n")
  for e in r.errors:
    result.add("  ERROR: " & e & "\n")
  for w in r.warnings:
    result.add("  WARN:  " & w & "\n")

# --- verifyQuery template ---

template verifyQuery*(schemaType: typedesc, q: untyped): untyped =
  when defined(nectoVerify):
    import necto/query_verifier
    block:
      let bq {.inject.} = q.toBoundQuery()
      let meta {.inject.} = schemaMeta(schemaType)
      let cols {.inject.} = q.extractColumns()
      let cfg {.inject.} = getDbConfig()
      let r = verifyQueryAgainstDb(cfg.host, cfg.port, cfg.user, cfg.password,
                                    cfg.database, meta.tableName, cols, bq.sql)
      if r.errors.len > 0 or r.warnings.len > 0:
        echo formatQueryResult(r)
      if r.errors.len > 0:
        quit(1)
  q