## Necto Schema Generator
##
## Reverse engineering на PostgreSQL таблици към necto_schema макро.
##
## Пример:
##   nim c -r src/necto_gen_schema --table users --module MyApp.User

import std/[strutils, sequtils]
import db_connector/db_postgres

type
  ColumnInfo* = object
    name*: string
    pgType*: string
    isNullable*: bool
    defaultValue*: string
    maxLength*: int
    isPrimaryKey*: bool
    isUnique*: bool
    isForeignKey*: bool
    foreignTable*: string
    foreignColumn*: string

  TableInfo* = object
    name*: string
    columns*: seq[ColumnInfo]
    hasTimestamps*: bool

# --- PostgreSQL → Nim type mapping ---

proc pgTypeToNim*(pgType: string): string =
  let lower = pgType.toLowerAscii
  case lower
  of "bigint": "int64"
  of "integer", "int", "serial", "bigserial": "int"
  of "smallint", "smallserial": "int16"
  of "text", "character varying", "varchar", "char", "character", "name": "string"
  of "uuid": "Uuid"
  of "boolean", "bool": "bool"
  of "timestamp with time zone", "timestamp without time zone": "DateTime"
  of "date": "Date"
  of "time without time zone", "time with time zone", "time": "TimeOfDay"
  of "numeric", "decimal": "Decimal"
  of "real": "float32"
  of "double precision": "float64"
  of "json", "jsonb": "JsonNode"
  of "bytea": "seq[byte]"
  of "point": "PgPoint"
  of "inet": "PgInet"
  of "cidr": "PgCidr"
  of "macaddr": "PgMacAddr"
  of "tsvector": "PgTsVector"
  of "tsquery": "PgTsQuery"
  else:
    if lower.endsWith("[]"):
      let inner = lower[0..^3].strip()
      "seq[" & pgTypeToNim(inner) & "]"
    else:
      "string"

proc pgTypeToNimWithOption*(col: ColumnInfo): string =
  let base = pgTypeToNim(col.pgType)
  if col.isNullable and base notin ["JsonNode", "seq[byte]"]:
    "Option[" & base & "]"
  else:
    base

# --- Information schema queries ---

proc getColumns*(conn: DbConn, tableName: string): seq[ColumnInfo] =
  let rows = conn.getAllRows(sql"""
    SELECT 
      column_name, 
      data_type, 
      is_nullable = 'YES',
      COALESCE(column_default, ''),
      COALESCE(character_maximum_length, 0)
    FROM information_schema.columns
    WHERE table_name = ?
    ORDER BY ordinal_position
  """, tableName)
  
  for row in rows:
    result.add(ColumnInfo(
      name: row[0],
      pgType: row[1],
      isNullable: row[2] == "t",
      defaultValue: row[3],
      maxLength: parseInt(row[4])
    ))

proc getPrimaryKeys*(conn: DbConn, tableName: string): seq[string] =
  let rows = conn.getAllRows(sql"""
    SELECT kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu 
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    WHERE tc.table_name = ?
      AND tc.constraint_type = 'PRIMARY KEY'
    ORDER BY kcu.ordinal_position
  """, tableName)
  for row in rows:
    result.add(row[0])

proc getUniqueColumns*(conn: DbConn, tableName: string): seq[string] =
  let rows = conn.getAllRows(sql"""
    SELECT kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu 
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    WHERE tc.table_name = ?
      AND tc.constraint_type = 'UNIQUE'
  """, tableName)
  for row in rows:
    result.add(row[0])

proc getForeignKeys*(conn: DbConn, tableName: string): seq[(string, string, string)] =
  ## Връща (column, foreign_table, foreign_column)
  let rows = conn.getAllRows(sql"""
    SELECT 
      kcu.column_name,
      ccu.table_name AS foreign_table_name,
      ccu.column_name AS foreign_column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu 
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu 
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.table_name = ?
      AND tc.constraint_type = 'FOREIGN KEY'
  """, tableName)
  for row in rows:
    result.add((row[0], row[1], row[2]))

proc inspectTable*(conn: DbConn, tableName: string): TableInfo =
  ## Инспектира таблица и връща пълна информация.
  result.name = tableName
  result.columns = getColumns(conn, tableName)
  
  let pks = getPrimaryKeys(conn, tableName)
  let uniques = getUniqueColumns(conn, tableName)
  let fks = getForeignKeys(conn, tableName)
  
  for col in result.columns.mitems:
    col.isPrimaryKey = col.name in pks
    col.isUnique = col.name in uniques
    for fk in fks:
      if fk[0] == col.name:
        col.isForeignKey = true
        col.foreignTable = fk[1]
        col.foreignColumn = fk[2]
  
  # Проверяваме дали има created_at/updated_at
  let hasCreated = result.columns.anyIt(it.name == "created_at")
  let hasUpdated = result.columns.anyIt(it.name == "updated_at")
  result.hasTimestamps = hasCreated and hasUpdated

# --- Code generation ---

proc toSchemaName*(tableName: string): string =
  ## Конвертира snake_case table name към CamelCase schema name.
  var parts = tableName.split('_')
  for i, p in parts.mpairs:
    if i == 0:
      p = p.capitalizeAscii
    else:
      p = p.capitalizeAscii
  parts.join("")

proc generateNimType*(col: ColumnInfo): string =
  ## Генерира Nim тип declaration за колона.
  let nimType = pgTypeToNimWithOption(col)
  var pragmas: seq[string] = @[]
  
  if col.isPrimaryKey:
    if col.defaultValue.contains("nextval"):
      pragmas.add("primary_key, auto_increment")
    else:
      pragmas.add("primary_key")
  
  if not col.isNullable and not col.isPrimaryKey:
    pragmas.add("not_null")
  
  if col.isUnique and not col.isPrimaryKey:
    pragmas.add("unique")
  
  if pragmas.len > 0:
    result = "  field " & col.name & ": " & nimType & " {" & pragmas.join(", ") & "}"
  else:
    result = "  field " & col.name & ": " & nimType

proc generateSchema*(info: TableInfo; moduleName: string = ""; schemaName: string = ""): string =
  ## Генерира пълен necto_schema код.
  let sName = if schemaName.len > 0: schemaName else: toSchemaName(info.name)
  
  var lines: seq[string] = @[]
  lines.add("## Auto-generated schema for table '" & info.name & "'")
  lines.add("")
  lines.add("import necto")
  lines.add("")
  lines.add("necto_schema " & sName & ":")
  lines.add("  table \"" & info.name & "\"")
  
  for col in info.columns:
    if col.name in ["created_at", "updated_at"] and info.hasTimestamps:
      continue
    lines.add(generateNimType(col))
  
  if info.hasTimestamps:
    lines.add("  timestamps")
  
  lines.join("\n")

proc generateSchemaFile*(conn: DbConn, tableName, outputPath: string; moduleName: string = ""; schemaName: string = "") =
  ## Генерира и записва schema файл.
  let info = inspectTable(conn, tableName)
  let code = generateSchema(info, moduleName, schemaName)
  writeFile(outputPath, code & "\n")
