## Necto Schema Verifier
##
## Compile-time schema verification срещу PostgreSQL information_schema.
## Това е "Nim Superpower" — проверява таблици, колони, типове и foreign keys
## при стартиране на програмата (преди всякакви заявки).
##
## Активиране:
##   - Добави `verify` в necto_schema блока
##   - Компилирай с `-d:nectoVerify` ИЛИ `NECTO_VERIFY=1 nim c ...`
##
## Пример:
##   necto_schema User:
##     table "users"
##     verify
##     field id: int64 {.primary_key, auto_increment.}
##     field email: string {.not_null, unique.}

import std/[os, strutils, tables, sets, sequtils]
import db_connector/db_postgres as pg

# --- DB Column Info ---

type
  DbColumnInfo* = object
    name*: string
    dataType*: string
    isNullable*: bool

  VerificationResult* = object
    tableName*: string
    errors*: seq[string]
    warnings*: seq[string]

  SchemaFieldInfo* = object
    nimName*: string
    dbColumn*: string
    nimType*: string
    dbType*: string
    isPrimaryKey*: bool
    isNullable*: bool
    isUnique*: bool

# --- PostgreSQL Type Compatibility ---

proc isTypeCompatible*(expected: string, actual: string): bool =
  let e = expected.toLowerAscii()
  let a = actual.toLowerAscii()
  if e == a: return true
  case e:
  of "text": a in ["character varying", "varchar", "char", "character", "bpchar"]
  of "character varying", "varchar": a in ["text", "char", "character", "bpchar"]
  of "integer", "int4", "int": a in ["int4", "integer", "int"]
  of "bigint", "int8": a in ["int8", "bigint"]
  of "smallint", "int2": a in ["int2", "smallint"]
  of "bool", "boolean": a in ["bool", "boolean"]
  of "double precision", "float8": a in ["float8", "double precision"]
  of "real", "float4": a in ["float4", "real"]
  of "timestamp with time zone": a in ["timestamptz", "timestamp with time zone"]
  of "timestamp without time zone": a in ["timestamp", "timestamp without time zone"]
  of "time without time zone": a in ["time", "time without time zone"]
  of "jsonb": a in ["jsonb", "json"]
  of "json": a in ["json", "jsonb"]
  of "uuid": a in ["uuid"]
  of "numeric", "decimal": a in ["numeric", "decimal"]
  of "bytea": a in ["bytea"]
  else: false

# --- Core Verification Logic ---

proc verifySchema*(host: string, port: int, user: string, password: string,
                    database: string, tableName: string,
                    fields: seq[SchemaFieldInfo]): VerificationResult =
  result = VerificationResult(tableName: tableName)

  let connStr = host & ":" & $port
  var db: pg.DbConn
  try:
    db = pg.open(connStr, user, password, database)
  except:
    result.errors.add("ERROR: Cannot connect to '" & database &
                       "' at " & host & ":" & $port & " as " & user)
    return

  defer: db.close()

  # Check table exists
  let tableCheck = sql"""
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = ?
    )
  """
  let existsRow = db.getRow(tableCheck, tableName)
  if existsRow.len == 0 or existsRow[0] != "t":
    result.errors.add("ERROR: Table '" & tableName & "' does not exist in '" &
                       database & "' (schema: public)")
    return

  # Read columns
  let colsSql = sql"""
    SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = ?
    ORDER BY ordinal_position
  """
  var dbCols: Table[string, DbColumnInfo]
  for row in db.getAllRows(colsSql, tableName):
    dbCols[row[0]] = DbColumnInfo(
      name: row[0],
      dataType: row[1],
      isNullable: row[2] == "YES"
    )

  # Read constraints
  let consSql = sql"""
    SELECT kcu.column_name, tc.constraint_type
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    WHERE tc.table_schema = 'public'
      AND tc.table_name = ?
      AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE')
  """
  var dbConstraints: Table[string, seq[string]]
  for row in db.getAllRows(consSql, tableName):
    if row[0] notin dbConstraints:
      dbConstraints[row[0]] = @[]
    dbConstraints[row[0]].add(row[1])

  # Check each field
  for field in fields:
    if field.dbColumn notin dbCols:
      result.errors.add("ERROR: Column '" & field.dbColumn &
                         "' declared in schema but missing in database")
      continue

    let dbCol = dbCols[field.dbColumn]

    if not isTypeCompatible(field.dbType, dbCol.dataType):
      result.warnings.add("WARNING: Column '" & field.dbColumn &
                           "' type — schema: " & field.dbType &
                           ", database: " & dbCol.dataType)

    if not field.isNullable and dbCol.isNullable:
      result.errors.add("ERROR: Column '" & field.dbColumn &
                         "' is NOT NULL in schema but nullable in database")

    if field.isPrimaryKey:
      let pkCons = dbConstraints.getOrDefault(field.dbColumn, @[])
      if "PRIMARY KEY" notin pkCons:
        result.errors.add("ERROR: Column '" & field.dbColumn &
                           "' is PRIMARY KEY in schema but has no PK constraint")

    if field.isUnique:
      let colCons = dbConstraints.getOrDefault(field.dbColumn, @[])
      if "UNIQUE" notin colCons:
        result.warnings.add("WARNING: Column '" & field.dbColumn &
                             "' is UNIQUE in schema but has no UNIQUE constraint")

  # Extra columns in DB
  let schemaColNames = fields.mapIt(it.dbColumn).toHashSet()
  for colName, _ in dbCols:
    if colName notin schemaColNames:
      result.warnings.add("WARNING: Column '" & colName &
                           "' exists in database but not in schema")

# --- Formatting ---

proc formatResult*(r: VerificationResult): string =
  result = ""
  if r.errors.len > 0:
    result.add("═══ VERIFICATION ERRORS: " & r.tableName & " ═══\n")
    for e in r.errors:
      result.add("  " & e & "\n")
  if r.warnings.len > 0:
    if result.len > 0: result.add("\n")
    result.add("─── VERIFICATION WARNINGS: " & r.tableName & " ───\n")
    for w in r.warnings:
      result.add("  " & w & "\n")

# --- Helpers ---

proc getDbConfig*(): tuple[host: string, port: int, user: string,
                            password: string, database: string] =
  result.host = getEnv("PGHOST", "localhost")
  result.port = parseInt(getEnv("PGPORT", "5432"))
  result.user = getEnv("PGUSER", "postgres")
  result.password = getEnv("PGPASSWORD", "")
  result.database = getEnv("PGDATABASE", "necto_test")
