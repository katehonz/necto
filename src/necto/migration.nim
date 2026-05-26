## Necto Migration
##
## DSL за дефиниране на миграции + глобален регистър.
## Всяка миграция се регистрира автоматично при зареждане на модула.
##
## Пример:
##   necto_migration CreateUsers, "20260526120000":
##     up:
##       createTable repo, "users", [
##         pk("id"),
##         col("name", "text", null = false),
##         timestamps()
##       ]
##
##     down:
##       dropTable repo, "users"

import std/[macros, strutils, tables, sequtils, algorithm]
import ./adapters/base
import ./repo
import ./errors

export base, errors

# --- Типове ---

type
  Migration* = ref object of RootObj
    version*: string
    name*: string

  MigrationDirection* = enum
    Up, Down

  MigrationEntry* = tuple
    version: string
    name: string
    factory: proc(): Migration

  ColumnDef* = object
    name*: string
    dbType*: string
    null*: bool
    default*: string
    primaryKey*: bool
    unique*: bool
    reference*: string

# --- Глобален регистър ---

var registeredMigrations*: seq[MigrationEntry] = @[]

proc registerMigration*(version: string, name: string, factory: proc(): Migration) =
  registeredMigrations.add((version, name, factory))

proc allMigrations*(): seq[MigrationEntry] =
  result = registeredMigrations
  result.sort do (a, b: MigrationEntry) -> int:
    cmp(a.version, b.version)

# --- Базови методи ---

method up*(m: Migration, repo: Repo) {.base.} =
  raise newException(MigrationError, "up not implemented for " & m.name)

method down*(m: Migration, repo: Repo) {.base.} =
  raise newException(MigrationError, "down not implemented for " & m.name)

# --- DSL Helpers ---

proc pk*(name: string = "id", dbType: string = "bigserial"): ColumnDef =
  ColumnDef(name: name, dbType: dbType, primaryKey: true, null: false)

proc col*(name: string, dbType: string; nullable: bool = true, default: string = "",
          unique: bool = false, reference: string = ""): ColumnDef =
  ColumnDef(name: name, dbType: dbType, null: nullable, default: default,
            unique: unique, reference: reference)

proc references*(tableName: string; colName: string = "", onDelete: string = "SET NULL"): ColumnDef =
  ## Ecto-style: създава FK колона като част от createTable.
  let fkCol = if colName.len > 0: colName else: tableName & "_id"
  ColumnDef(
    name: fkCol,
    dbType: "bigint",
    null: true,
    reference: tableName & "(id)"
  )

proc timestamps*(): seq[ColumnDef] =
  @[
    col("created_at", "timestamp with time zone", nullable = false, default = "NOW()"),
    col("updated_at", "timestamp with time zone", nullable = false, default = "NOW()")
  ]

# --- SQL генератори ---

proc columnToSql(c: ColumnDef): string =
  if c.primaryKey and c.dbType == "bigserial":
    return "\"" & c.name & "\" BIGSERIAL PRIMARY KEY"
  var parts = @["\"" & c.name & "\"", c.dbType]
  if c.primaryKey:
    parts.add("PRIMARY KEY")
  if not c.null:
    parts.add("NOT NULL")
  if c.default.len > 0:
    parts.add("DEFAULT " & c.default)
  if c.unique:
    parts.add("UNIQUE")
  if c.reference.len > 0:
    parts.add("REFERENCES " & c.reference)
  parts.join(" ")

proc createTableSql*(tableName: string, columns: seq[ColumnDef]): string =
  var parts: seq[string] = @[]
  for c in columns:
    parts.add("  " & columnToSql(c))
  "CREATE TABLE IF NOT EXISTS \"" & tableName & "\" (\n" & parts.join(",\n") & "\n)"

proc dropTableSql*(tableName: string): string =
  "DROP TABLE IF EXISTS \"" & tableName & "\""

proc addColumnSql*(tableName, colName, dbType: string;
                   nullable: bool = true, default: string = "",
                   unique: bool = false): string =
  var parts = @["ALTER TABLE \"" & tableName & "\" ADD COLUMN \"" & colName & "\" " & dbType]
  if not nullable: parts.add("NOT NULL")
  if default.len > 0: parts.add("DEFAULT " & default)
  if unique: parts.add("UNIQUE")
  parts.join(" ")

proc dropColumnSql*(tableName, colName: string): string =
  "ALTER TABLE \"" & tableName & "\" DROP COLUMN IF EXISTS \"" & colName & "\""

proc renameColumnSql*(tableName, oldName, newName: string): string =
  "ALTER TABLE \"" & tableName & "\" RENAME COLUMN \"" & oldName & "\" TO \"" & newName & "\""

proc renameTableSql*(oldName, newName: string): string =
  "ALTER TABLE \"" & oldName & "\" RENAME TO \"" & newName & "\""

proc addReferenceSql*(tableName, refTable, colName: string;
                      onDelete: string = "SET NULL"): string =
  let fkCol = if colName.len > 0: colName else: refTable & "_id"
  "ALTER TABLE \"" & tableName & "\" ADD COLUMN \"" & fkCol &
  "\" BIGINT REFERENCES \"" & refTable & "\"(id) ON DELETE " & onDelete

proc removeReferenceSql*(tableName, refTable, colName: string): string =
  let fkCol = if colName.len > 0: colName else: refTable & "_id"
  "ALTER TABLE \"" & tableName & "\" DROP COLUMN IF EXISTS \"" & fkCol & "\""

proc createIndexSql*(tableName: string, columns: seq[string];
                     unique: bool = false, indexName: string = ""): string =
  var name = indexName
  if name.len == 0: name = tableName & "_" & columns.join("_") & "_idx"
  let uniq = if unique: "UNIQUE " else: ""
  let colList = columns.mapIt("\"" & it & "\"").join(", ")
  "CREATE " & uniq & "INDEX IF NOT EXISTS \"" & name & "\" ON \"" & tableName & "\" (" & colList & ")"

proc dropIndexSql*(tableName: string, columns: seq[string] = @[];
                   indexName: string = ""): string =
  var name = indexName
  if name.len == 0 and columns.len > 0: name = tableName & "_" & columns.join("_") & "_idx"
  if name.len > 0: "DROP INDEX IF EXISTS \"" & name & "\"" else: ""

# --- Удобни shortcut функции (викат се вътре в up/down) ---

proc createTable*(repo: auto, tableName: string, columns: seq[ColumnDef]) =
  repo.exec(createTableSql(tableName, columns))

proc dropTable*(repo: auto, tableName: string) =
  repo.exec(dropTableSql(tableName))

proc addColumn*(repo: auto, tableName, colName, dbType: string;
                nullable: bool = true, default: string = "", unique: bool = false) =
  repo.exec(addColumnSql(tableName, colName, dbType, nullable, default, unique))

proc dropColumn*(repo: auto, tableName, colName: string) =
  repo.exec(dropColumnSql(tableName, colName))

proc renameColumn*(repo: auto, tableName, oldName, newName: string) =
  repo.exec(renameColumnSql(tableName, oldName, newName))

proc renameTable*(repo: auto, oldName, newName: string) =
  repo.exec(renameTableSql(oldName, newName))

proc addReference*(repo: auto, tableName, refTable: string;
                   colName: string = "", onDelete: string = "SET NULL") =
  repo.exec(addReferenceSql(tableName, refTable, colName, onDelete))

proc removeReference*(repo: auto, tableName, refTable: string;
                      colName: string = "") =
  repo.exec(removeReferenceSql(tableName, refTable, colName))

proc createIndex*(repo: auto, tableName: string, columns: seq[string];
                  unique: bool = false, indexName: string = "") =
  repo.exec(createIndexSql(tableName, columns, unique, indexName))

proc dropIndex*(repo: auto, tableName: string, columns: seq[string] = @[];
                indexName: string = "") =
  let sql = dropIndexSql(tableName, columns, indexName)
  if sql.len > 0: repo.exec(sql)

proc execSql*(repo: auto, sql: string) =
  repo.exec(sql)

proc execute*(repo: auto, sql: string) =
  ## Ecto-style alias за execSql.
  repo.exec(sql)

proc modify*(repo: auto, tableName, colName, newDbType: string;
             nullable: bool = true, default: string = "") =
  ## Ecto-style: променя тип/конфигурация на колона.
  var parts = @["ALTER TABLE \"" & tableName & "\" ALTER COLUMN \"" & colName & "\" TYPE " & newDbType]
  if not nullable and default.len > 0:
    parts.add("ALTER TABLE \"" & tableName & "\" ALTER COLUMN \"" & colName & "\" SET DEFAULT " & default)
    parts.add("ALTER TABLE \"" & tableName & "\" ALTER COLUMN \"" & colName & "\" SET NOT NULL")
  elif default.len > 0:
    parts.add("ALTER TABLE \"" & tableName & "\" ALTER COLUMN \"" & colName & "\" SET DEFAULT " & default)
  repo.exec(parts.join("; "))

proc addConstraint*(repo: auto, tableName, constraintName, definition: string) =
  ## Добавя именуван constraint (CHECK, UNIQUE, etc).
  repo.exec("ALTER TABLE \"" & tableName & "\" ADD CONSTRAINT \"" &
            constraintName & "\" " & definition)

proc dropConstraint*(repo: auto, tableName, constraintName: string) =
  ## Премахва именуван constraint.
  repo.exec("ALTER TABLE \"" & tableName & "\" DROP CONSTRAINT IF EXISTS \"" &
            constraintName & "\"")

# --- Макро за дефиниране на миграция с auto-registration ---

macro necto_migration*(name: untyped, version: static[string], body: untyped): untyped =
  result = newStmtList()

  var upBody: NimNode = newEmptyNode()
  var downBody: NimNode = newEmptyNode()

  for child in body:
    if child.kind in {nnkCall, nnkCommand}:
      let cmdName = $child[0]
      if cmdName == "up":
        upBody = child[1]
      elif cmdName == "down":
        downBody = child[1]

  let typeName = name
  let typeNameStr = $name

  # Ръчно изграждане на AST (без quote do, за избягване на indentation issues)
  var blockStmts = newStmtList()

  # type TypeName* = ref object of Migration
  blockStmts.add(newTree(nnkTypeSection,
    newTree(nnkTypeDef,
      newTree(nnkPostfix, newIdentNode("*"), typeName),
      newEmptyNode(),
      newTree(nnkRefTy,
        newTree(nnkObjectTy,
          newEmptyNode(),
          newTree(nnkOfInherit, newIdentNode("Migration")),
          newTree(nnkRecList)
        )
      )
    )
  ))

  # proc newTypeName*(): TypeName = TypeName(version: version, name: typeNameStr)
  blockStmts.add(newProc(
    name = newIdentNode("new" & $name),
    params = [typeName],
    body = newStmtList().add(
      nnkObjConstr.newTree(
        typeName,
        nnkExprColonExpr.newTree(newIdentNode("version"), newLit(version)),
        nnkExprColonExpr.newTree(newIdentNode("name"), newLit(typeNameStr))
      )
    ),
    procType = nnkProcDef
  ))

  # method up*(m: TypeName, repo: Repo) = upBody
  blockStmts.add(newProc(
    name = newIdentNode("up"),
    params = [newEmptyNode(),
      newIdentDefs(newIdentNode("m"), typeName),
      newIdentDefs(newIdentNode("repo"), newIdentNode("Repo"))
    ],
    body = upBody,
    procType = nnkMethodDef
  ))

  # method down*(m: TypeName, repo: Repo) = downBody
  blockStmts.add(newProc(
    name = newIdentNode("down"),
    params = [newEmptyNode(),
      newIdentDefs(newIdentNode("m"), typeName),
      newIdentDefs(newIdentNode("repo"), newIdentNode("Repo"))
    ],
    body = downBody,
    procType = nnkMethodDef
  ))

  # registerMigration(version, name, proc(): Migration = newTypeName())
  var lambdaBody = newStmtList()
  lambdaBody.add(nnkAsgn.newTree(
    newIdentNode("result"),
    newCall(newIdentNode("new" & $name))
  ))

  var regCall = newCall(
    newIdentNode("registerMigration"),
    newLit(version),
    newLit(typeNameStr),
    newTree(nnkLambda,
      newEmptyNode(),
      newEmptyNode(),
      newEmptyNode(),
      newTree(nnkFormalParams, newIdentNode("Migration")),
      newEmptyNode(),
      newEmptyNode(),
      lambdaBody
    )
  )

  blockStmts.add(regCall)

  result.add(blockStmts)
