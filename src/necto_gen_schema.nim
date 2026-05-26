## Necto Schema Generator CLI
##
## Генерира necto_schema от съществуваща PostgreSQL таблица.
##
## Пример:
##   nim c -r src/necto_gen_schema --table users --output src/models/user.nim
##   nim c -r src/necto_gen_schema --table users --module MyApp.User

import std/[os, strutils, parseopt, strformat]
import necto/schema_generator

proc showHelp() =
  echo """
Necto Schema Generator

Usage:
  necto_gen_schema --table TABLE_NAME [options]

Options:
  --table, -t      PostgreSQL table name (required)
  --output, -o     Output file path (default: stdout)
  --module, -m     Module/package name for the generated file
  --schema, -s     Schema type name (default: CamelCase of table)
  --host           PostgreSQL host (default: localhost)
  --port           PostgreSQL port (default: 5432)
  --user, -u       PostgreSQL user (default: postgres)
  --password, -p   PostgreSQL password (default: empty)
  --database, -d   PostgreSQL database (default: postgres)
  --help, -h       Show this help

Examples:
  necto_gen_schema --table users --output src/models/user.nim
  necto_gen_schema -t posts -o src/models/post.nim -m MyApp.Post
"""

proc main() =
  var tableName = ""
  var outputPath = ""
  var moduleName = ""
  var schemaName = ""
  var host = "localhost"
  var port = 5432
  var user = "postgres"
  var password = ""
  var database = "postgres"

  var opt = initOptParser(commandLineParams())
  for kind, key, val in opt.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "table", "t": tableName = val
      of "output", "o": outputPath = val
      of "module", "m": moduleName = val
      of "schema", "s": schemaName = val
      of "host": host = val
      of "port": port = parseInt(val)
      of "user", "u": user = val
      of "password", "p": password = val
      of "database", "d": database = val
      of "help", "h":
        showHelp()
        quit(0)
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdArgument:
      if tableName.len == 0:
        tableName = key
    of cmdEnd: discard

  if tableName.len == 0:
    echo "Error: --table is required"
    showHelp()
    quit(1)

  # Connect to PostgreSQL
  let connStr = fmt"host={host} port={port} dbname={database} user={user} password={password}"
  let conn = open("", "", "", connStr)
  defer: close(conn)

  # Generate schema
  let info = inspectTable(conn, tableName)
  let code = generateSchema(info, moduleName, schemaName)

  if outputPath.len > 0:
    writeFile(outputPath, code & "\n")
    echo fmt"Generated schema written to {outputPath}"
  else:
    echo code

when isMainModule:
  main()
