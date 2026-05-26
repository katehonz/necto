## Necto Migration
##
## DSL за дефиниране на миграции.
##
## Пример:
##   necto_migration CreateUsers, "20260526120000":
##     def up:
##       create table(:users) do |t|
##         t.primary_key :id, :bigserial
##         t.string :name, null: false
##         t.timestamps
##       end
##
##     def down:
##       drop table(:users)

import std/[macros, strutils, tables, times]
import ./adapters/base
import ./errors

export base, errors

type
  Migration* = ref object of RootObj
    version*: string
    name*: string

  MigrationDirection* = enum
    Up, Down

# --- Базови методи ---

method up*(m: Migration) {.base.} =
  raise newException(MigrationError, "up not implemented for " & m.name)

method down*(m: Migration) {.base.} =
  raise newException(MigrationError, "down not implemented for " & m.name)

# --- DDL Helpers ---

proc createTableSql*(name: string, columns: seq[string]): string =
  "CREATE TABLE \"" & name & "\" (\n  " & columns.join(",\n  ") & "\n)"

proc dropTableSql*(name: string): string =
  "DROP TABLE IF EXISTS \"" & name & "\""

proc addColumnSql*(table, name, dbType: string; nullable: bool = true; unique: bool = false): string =
  var parts = @["ALTER TABLE \"" & table & "\" ADD COLUMN \"" & name & "\" " & dbType]
  if not nullable:
    parts.add("NOT NULL")
  if unique:
    parts.add("UNIQUE")
  parts.join(" ")

proc dropColumnSql*(table, name: string): string =
  "ALTER TABLE \"" & table & "\" DROP COLUMN \"" & name & "\""

proc createIndexSql*(table, column: string; unique: bool = false): string =
  let idxName = table & "_" & column & "_idx"
  let uniq = if unique: "UNIQUE " else: ""
  "CREATE " & uniq & "INDEX \"" & idxName & "\" ON \"" & table & "\" (\"" & column & "\")"

proc dropIndexSql*(table, column: string): string =
  let idxName = table & "_" & column & "_idx"
  "DROP INDEX IF EXISTS \"" & idxName & "\""

# --- Макро за дефиниране на миграция ---

macro necto_migration*(name: untyped, version: static[string], body: untyped): untyped =
  ## Дефинира миграционен клас.
  result = newStmtList()

  var upBody: NimNode = newEmptyNode()
  var downBody: NimNode = newEmptyNode()

  for child in body:
    if child.kind == nnkCall:
      if $child[0] == "up":
        upBody = child[1]
      elif $child[0] == "down":
        downBody = child[1]

  let typeName = name

  result.add quote do:
    type `typeName`* = ref object of Migration

    proc new`typeName`*(): `typeName` =
      `typeName`(version: `version`, name: astToStr(`name`))

    method up*(m: `typeName`) =
      `upBody`

    method down*(m: `typeName`) =
      `downBody`
