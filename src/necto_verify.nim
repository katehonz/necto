## Necto Verify — Standalone Schema Verification Tool
##
## Проверява дали Nim schema дефинициите съвпадат с реалната PostgreSQL база данни.
## Полезно за CI/CD pipelines и pre-commit hooks.
##
## Употреба:
##   nim c -r --path:src src/necto_verify.nim --table=users --fields=id:int64:bigint:pk,name:string:text
##
##   или с environment variables:
##   NECTO_VERIFY=1 nim c -r --path:src src/necto_verify.nim

import std/[os, strutils, parseopt]
import necto/schema_verifier

proc parseFieldDef(def: string): SchemaFieldInfo =
  ## Парсира поле от формата: name:nimType:dbType[:pk][:notnull][:unique]
  let parts = def.split(':')
  if parts.len < 3:
    echo "ERROR: Invalid field definition: " & def
    echo "  Expected: name:nimType:dbType[:pk][:notnull][:unique]"
    quit(1)

  result.nimName = parts[0]
  result.dbColumn = parts[0]  # same as nimName by default
  result.nimType = parts[1]
  result.dbType = parts[2]
  result.isNullable = true  # nullable by default

  for i in 3..<parts.len:
    case parts[i].toLowerAscii()
    of "pk": result.isPrimaryKey = true
    of "notnull", "not_null": result.isNullable = false
    of "unique": result.isUnique = true
    of "dcol": result.dbColumn = parts[i+1]  # explicit db column name
    else: discard

proc printUsage() =
  echo """
Necto Verify — Schema Verification Tool

Употреба:
  necto_verify [options] --table=NAME --field=NAME:TYPE:DBTYPE[:flags]...

Options:
  --table=NAME          Име на таблицата
  --field=DEF           Дефиниция на поле (може да се повтаря)
  --host=HOST           PostgreSQL host (default: $PGHOST или localhost)
  --port=PORT           PostgreSQL port (default: $PGPORT или 5432)
  --user=USER           PostgreSQL user (default: $PGUSER или postgres)
  --password=PASS       PostgreSQL password (default: $PGPASSWORD)
  --database=DB         PostgreSQL database (default: $PGDATABASE или necto_test)
  --help                Това съобщение

Field flags:
  pk                    Primary key
  notnull               NOT NULL
  unique                UNIQUE constraint
  dcol=NAME             Explicit database column name

Примери:
  necto_verify --table=users \
    --field=id:int64:bigint:pk:notnull \
    --field=name:string:text:notnull \
    --field=email:string:text:unique

Environment:
  PGUSER, PGPASSWORD, PGHOST, PGPORT, PGDATABASE
"""

# --- Main ---

proc main() =
  var
    tableName: string
    fields: seq[SchemaFieldInfo]
    host = getEnv("PGHOST", "localhost")
    port = parseInt(getEnv("PGPORT", "5432"))
    user = getEnv("PGUSER", "postgres")
    password = getEnv("PGPASSWORD", "")
    database = getEnv("PGDATABASE", "necto_test")

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "table": tableName = val
      of "field": fields.add(parseFieldDef(val))
      of "host": host = val
      of "port": port = parseInt(val)
      of "user": user = val
      of "password": password = val
      of "database": database = val
      of "help": printUsage(); quit(0)
      else:
        echo "Unknown option: --" & key
        printUsage()
        quit(1)
    of cmdShortOption:
      case key
      of "h": printUsage(); quit(0)
      else: discard
    of cmdArgument: discard
    of cmdEnd: break

  if tableName.len == 0:
    echo "ERROR: --table is required"
    printUsage()
    quit(1)

  if fields.len == 0:
    echo "ERROR: at least one --field is required"
    printUsage()
    quit(1)

  echo "═══ Necto Schema Verification ═══"
  echo "  Table: " & tableName
  echo "  Database: " & database & " on " & host & ":" & $port
  echo "  Fields: " & $fields.len
  echo ""

  let result = verifySchema(host, port, user, password, database, tableName, fields)

  if result.errors.len == 0 and result.warnings.len == 0:
    echo "✅ Schema verification PASSED — all " & $fields.len & " fields match."
    quit(0)

  echo formatResult(result)

  if result.errors.len > 0:
    echo ""
    echo "❌ Schema verification FAILED with " & $result.errors.len & " error(s)."
    quit(1)
  else:
    echo ""
    echo "⚠️  Schema verification passed with " & $result.warnings.len & " warning(s)."
    quit(0)

main()