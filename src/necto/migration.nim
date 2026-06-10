## Necto Migration
##
## DSL за дефиниране на миграции + глобален регистър.
## Всяка миграция се регистрира автоматично при зареждане на модула.
##
## Пример:
##   necto_migration CreateUsers, "20260526120000":
##     up:
##       createTable repo, "users", cols(pk("id"), col("name", "text", nullable = false))
##         & timestamps()
##
##     down:
##       dropTable repo, "users"

import std/[macros, strutils, tables, sequtils, algorithm]
import checksums/md5
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
    checksum: string
    factory: proc(): Migration

  ColumnDef* = object
    name*: string
    dbType*: string
    null*: bool
    default*: string
    primaryKey*: bool
    unique*: bool
    reference*: string
    onDelete*: string

# --- Глобален регистър ---

var registeredMigrations*: seq[MigrationEntry] = @[]

proc registerMigration*(version: string, name: string, checksum: string, factory: proc(): Migration) =
  registeredMigrations.add((version, name, checksum, factory))

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
    reference: tableName & "(id)",
    onDelete: onDelete
  )

proc timestamps*(): seq[ColumnDef] =
  @[
    col("created_at", "timestamp with time zone", nullable = false, default = "NOW()"),
    col("updated_at", "timestamp with time zone", nullable = false, default = "NOW()")
  ]

proc cols*(defs: varargs[ColumnDef]): seq[ColumnDef] =
  ## Helper to build column lists: cols(pk("id"), col("name", "text")).
  result = @[]
  for d in defs:
    result.add(d)

proc cols*(defs: seq[ColumnDef]): seq[ColumnDef] =
  ## Overload that accepts a seq directly (e.g., from timestamps()).
  result = defs

# --- Dialect-aware helpers ---

proc translateDbType*(pgType: string; dialect: SqlDialect = pdPostgres): string =
  ## Превежда PostgreSQL типове към диалект-специфичен еквивалент.
  if dialect == pdPostgres:
    return pgType
  if dialect == pdSqlite:
    case pgType.toLowerAscii()
    of "bigserial", "serial":
      result = "INTEGER PRIMARY KEY AUTOINCREMENT"
    of "integer", "int", "smallint", "bigint":
      result = "INTEGER"
    of "text":
      result = "TEXT"
    of "boolean":
      result = "INTEGER"
    of "double precision", "numeric":
      result = "REAL"
    of "timestamp with time zone", "timestamp without time zone", "date", "time without time zone":
      result = "TEXT"
    of "jsonb", "json":
      result = "TEXT"
    of "uuid":
      result = "TEXT"
    of "bytea":
      result = "BLOB"
    else:
      if pgType.endsWith("[]"):
        result = "TEXT"
      else:
        result = pgType
    return
  # MariaDB
  case pgType.toLowerAscii()
  of "bigserial":
    result = "BIGINT AUTO_INCREMENT PRIMARY KEY"
  of "serial":
    result = "INT AUTO_INCREMENT PRIMARY KEY"
  of "integer", "int":
    result = "INT"
  of "smallint":
    result = "SMALLINT"
  of "bigint":
    result = "BIGINT"
  of "text":
    result = "TEXT"
  of "boolean":
    result = "TINYINT(1)"
  of "double precision":
    result = "DOUBLE"
  of "timestamp with time zone", "timestamp without time zone":
    result = "DATETIME(6)"
  of "date":
    result = "DATE"
  of "time without time zone":
    result = "TIME"
  of "jsonb", "json":
    result = "JSON"
  of "uuid":
    result = "CHAR(36)"
  of "numeric":
    result = "DECIMAL(38,10)"
  of "bytea":
    result = "BLOB"
  else:
    if pgType.endsWith("[]"):
      result = "JSON"
    else:
      result = pgType

proc dialectQuote*(name: string; dialect: SqlDialect = pdPostgres): string =
  ## Огражда идентификатор с подходящи кавички за диалекта.
  case dialect
  of pdMariaDb, pdSqlite: "`" & name & "`"
  else: "\"" & name & "\""

proc getRepoDialect(repo: Repo): SqlDialect =
  if repo.adapter != nil:
    result = repo.adapter.dialect
  else:
    result = pdPostgres

# --- SQL генератори ---

proc columnToSql(c: ColumnDef; dialect: SqlDialect = pdPostgres): string =
  let translatedType = translateDbType(c.dbType, dialect)
  if c.primaryKey and c.dbType == "bigserial":
    return dialectQuote(c.name, dialect) & " " & translatedType
  var parts = @[dialectQuote(c.name, dialect), translatedType]
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
    if c.onDelete.len > 0:
      parts.add("ON DELETE " & c.onDelete)
  parts.join(" ")

proc createTableSql*(tableName: string, columns: seq[ColumnDef]; dialect: SqlDialect = pdPostgres): string =
  var parts: seq[string] = @[]
  for c in columns:
    parts.add("  " & columnToSql(c, dialect))
  "CREATE TABLE IF NOT EXISTS " & dialectQuote(tableName, dialect) & " (\n" & parts.join(",\n") & "\n)"

proc dropTableSql*(tableName: string; dialect: SqlDialect = pdPostgres): string =
  "DROP TABLE IF EXISTS " & dialectQuote(tableName, dialect)

proc addColumnSql*(tableName, colName, dbType: string;
                   nullable: bool = true, default: string = "",
                   unique: bool = false; dialect: SqlDialect = pdPostgres): string =
  var parts = @["ALTER TABLE " & dialectQuote(tableName, dialect) & " ADD COLUMN " & dialectQuote(colName, dialect) & " " & translateDbType(dbType, dialect)]
  if not nullable: parts.add("NOT NULL")
  if default.len > 0: parts.add("DEFAULT " & default)
  if unique: parts.add("UNIQUE")
  parts.join(" ")

proc dropColumnSql*(tableName, colName: string; dialect: SqlDialect = pdPostgres): string =
  if dialect == pdMariaDb or dialect == pdSqlite:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP COLUMN " & dialectQuote(colName, dialect)
  else:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP COLUMN IF EXISTS " & dialectQuote(colName, dialect)

proc renameColumnSql*(tableName, oldName, newName: string; dialect: SqlDialect = pdPostgres): string =
  if dialect == pdMariaDb:
    # MariaDB uses CHANGE COLUMN (needs type info, but we don't have it here — placeholder)
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " CHANGE COLUMN " & dialectQuote(oldName, dialect) & " " & dialectQuote(newName, dialect)
  else:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " RENAME COLUMN " & dialectQuote(oldName, dialect) & " TO " & dialectQuote(newName, dialect)

proc renameTableSql*(oldName, newName: string; dialect: SqlDialect = pdPostgres): string =
  "ALTER TABLE " & dialectQuote(oldName, dialect) & " RENAME TO " & dialectQuote(newName, dialect)

proc addReferenceSql*(tableName, refTable, colName: string;
                      onDelete: string = "SET NULL"; dialect: SqlDialect = pdPostgres): string =
  let fkCol = if colName.len > 0: colName else: refTable & "_id"
  let fkName = "fk_" & tableName & "_" & fkCol
  if dialect == pdSqlite:
    # SQLite does not support ALTER TABLE ADD CONSTRAINT.
    # We add the column without the FK constraint.
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " ADD COLUMN " & dialectQuote(fkCol, dialect) & " INTEGER"
  else:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " ADD COLUMN " & dialectQuote(fkCol, dialect) &
    " BIGINT, ADD CONSTRAINT " & dialectQuote(fkName, dialect) &
    " FOREIGN KEY (" & dialectQuote(fkCol, dialect) & ") REFERENCES " & dialectQuote(refTable, dialect) & "(id) ON DELETE " & onDelete

proc removeReferenceSql*(tableName, refTable, colName: string; dialect: SqlDialect = pdPostgres): string =
  let fkCol = if colName.len > 0: colName else: refTable & "_id"
  let fkName = "fk_" & tableName & "_" & fkCol
  if dialect == pdMariaDb:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP FOREIGN KEY " & dialectQuote(fkName, dialect) &
    ", DROP COLUMN " & dialectQuote(fkCol, dialect)
  elif dialect == pdSqlite:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP COLUMN " & dialectQuote(fkCol, dialect)
  else:
    "ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP CONSTRAINT IF EXISTS " & dialectQuote(fkName, dialect) &
    ", DROP COLUMN IF EXISTS " & dialectQuote(fkCol, dialect)

proc createIndexSql*(tableName: string, columns: seq[string];
                     unique: bool = false, indexName: string = ""; dialect: SqlDialect = pdPostgres): string =
  var name = indexName
  if name.len == 0: name = tableName & "_" & columns.join("_") & "_idx"
  let uniq = if unique: "UNIQUE " else: ""
  let colList = columns.mapIt(dialectQuote(it, dialect)).join(", ")
  if dialect == pdMariaDb:
    "CREATE " & uniq & "INDEX " & dialectQuote(name, dialect) & " ON " & dialectQuote(tableName, dialect) & " (" & colList & ")"
  else:
    "CREATE " & uniq & "INDEX IF NOT EXISTS " & dialectQuote(name, dialect) & " ON " & dialectQuote(tableName, dialect) & " (" & colList & ")"

proc dropIndexSql*(tableName: string, columns: seq[string] = @[];
                   indexName: string = ""; dialect: SqlDialect = pdPostgres): string =
  var name = indexName
  if name.len == 0 and columns.len > 0: name = tableName & "_" & columns.join("_") & "_idx"
  if name.len > 0:
    if dialect == pdMariaDb:
      "DROP INDEX " & dialectQuote(name, dialect) & " ON " & dialectQuote(tableName, dialect)
    else:
      "DROP INDEX IF EXISTS " & dialectQuote(name, dialect)
  else:
    ""

# --- Удобни shortcut функции (викат се вътре в up/down) ---

proc createTable*(repo: auto, tableName: string, columns: seq[ColumnDef]) =
  repo.exec(createTableSql(tableName, columns, getRepoDialect(repo)))

proc dropTable*(repo: auto, tableName: string) =
  repo.exec(dropTableSql(tableName, getRepoDialect(repo)))

proc addColumn*(repo: auto, tableName, colName, dbType: string;
                nullable: bool = true, default: string = "", unique: bool = false) =
  repo.exec(addColumnSql(tableName, colName, dbType, nullable, default, unique, getRepoDialect(repo)))

proc dropColumn*(repo: auto, tableName, colName: string) =
  repo.exec(dropColumnSql(tableName, colName, getRepoDialect(repo)))

proc renameColumn*(repo: auto, tableName, oldName, newName: string) =
  repo.exec(renameColumnSql(tableName, oldName, newName, getRepoDialect(repo)))

proc renameTable*(repo: auto, oldName, newName: string) =
  repo.exec(renameTableSql(oldName, newName, getRepoDialect(repo)))

proc addReference*(repo: auto, tableName, refTable: string;
                   colName: string = "", onDelete: string = "SET NULL") =
  repo.exec(addReferenceSql(tableName, refTable, colName, onDelete, getRepoDialect(repo)))

proc removeReference*(repo: auto, tableName, refTable: string;
                      colName: string = "") =
  repo.exec(removeReferenceSql(tableName, refTable, colName, getRepoDialect(repo)))

proc createIndex*(repo: auto, tableName: string, columns: seq[string];
                  unique: bool = false, indexName: string = "") =
  repo.exec(createIndexSql(tableName, columns, unique, indexName, getRepoDialect(repo)))

proc dropIndex*(repo: auto, tableName: string, columns: seq[string] = @[];
                indexName: string = "") =
  let sql = dropIndexSql(tableName, columns, indexName, getRepoDialect(repo))
  if sql.len > 0: repo.exec(sql)

proc execSql*(repo: auto, sql: string) =
  repo.exec(sql)

proc execute*(repo: auto, sql: string) =
  ## Ecto-style alias за execSql.
  repo.exec(sql)

proc modify*(repo: auto, tableName, colName, newDbType: string;
             nullable: bool = true, default: string = "") =
  ## Ecto-style: променя тип/конфигурация на колона.
  let dialect = getRepoDialect(repo)
  if dialect == pdSqlite:
    raise newException(MigrationError, "SQLite does not support ALTER TABLE MODIFY COLUMN. Use recreate table instead.")
  var parts: seq[string]
  if dialect == pdMariaDb:
    parts.add("ALTER TABLE " & dialectQuote(tableName, dialect) & " MODIFY COLUMN " & dialectQuote(colName, dialect) & " " & translateDbType(newDbType, dialect))
  else:
    parts.add("ALTER TABLE " & dialectQuote(tableName, dialect) & " ALTER COLUMN " & dialectQuote(colName, dialect) & " TYPE " & translateDbType(newDbType, dialect))
  if default.len > 0:
    parts.add("ALTER TABLE " & dialectQuote(tableName, dialect) & " ALTER COLUMN " & dialectQuote(colName, dialect) & " SET DEFAULT " & default)
  if not nullable:
    parts.add("ALTER TABLE " & dialectQuote(tableName, dialect) & " ALTER COLUMN " & dialectQuote(colName, dialect) & " SET NOT NULL")
  repo.exec(parts.join("; "))

proc addConstraint*(repo: auto, tableName, constraintName, definition: string) =
  ## Добавя именуван constraint (CHECK, UNIQUE, etc).
  let dialect = getRepoDialect(repo)
  if dialect == pdSqlite:
    raise newException(MigrationError, "SQLite does not support ALTER TABLE ADD CONSTRAINT. Define constraints in CREATE TABLE instead.")
  repo.exec("ALTER TABLE " & dialectQuote(tableName, dialect) & " ADD CONSTRAINT " &
            dialectQuote(constraintName, dialect) & " " & definition)

proc dropConstraint*(repo: auto, tableName, constraintName: string) =
  ## Премахва именуван constraint.
  let dialect = getRepoDialect(repo)
  if dialect == pdSqlite:
    raise newException(MigrationError, "SQLite does not support ALTER TABLE DROP CONSTRAINT.")
  if dialect == pdMariaDb:
    repo.exec("ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP CONSTRAINT " &
              dialectQuote(constraintName, dialect))
  else:
    repo.exec("ALTER TABLE " & dialectQuote(tableName, dialect) & " DROP CONSTRAINT IF EXISTS " &
              dialectQuote(constraintName, dialect))

# --- Макро за дефиниране на миграция с auto-registration ---

proc reverseMigrationStmt(stmt: NimNode): NimNode =
  ## Инвертира една миграционна операция за `change` direction.
  ## Поддържа: createTable→dropTable, addColumn→dropColumn,
  ## addIndex→dropIndex, addReference→removeReference,
  ## renameTable, renameColumn.
  if stmt.kind in {nnkCall, nnkCommand}:
    let fnName = $stmt[0]
    case fnName
    of "createTable":
      # createTable(repo, name, cols) → dropTable(repo, name)
      if stmt.len >= 3:
        result = newCall(newIdentNode("dropTable"), stmt[1], stmt[2])
      else:
        result = newEmptyNode()
    of "dropTable":
      # dropTable не е reversible без schema info — игнорираме
      result = newEmptyNode()
    of "addColumn":
      # addColumn(repo, table, col, type, ...) → dropColumn(repo, table, col)
      if stmt.len >= 4:
        result = newCall(newIdentNode("dropColumn"), stmt[1], stmt[2], stmt[3])
      else:
        result = newEmptyNode()
    of "dropColumn":
      result = newEmptyNode()
    of "renameTable":
      # renameTable(repo, old, new) → renameTable(repo, new, old)
      if stmt.len >= 4:
        result = newCall(newIdentNode("renameTable"), stmt[1], stmt[3], stmt[2])
      else:
        result = newEmptyNode()
    of "renameColumn":
      # renameColumn(repo, table, old, new) → renameColumn(repo, table, new, old)
      if stmt.len >= 5:
        result = newCall(newIdentNode("renameColumn"), stmt[1], stmt[2], stmt[4], stmt[3])
      else:
        result = newEmptyNode()
    of "createIndex":
      # createIndex(repo, table, columns, ...) → dropIndex(repo, table, columns, ...)
      if stmt.len >= 4:
        result = newCall(newIdentNode("dropIndex"))
        for i in 1..<stmt.len:
          result.add(stmt[i])
      else:
        result = newEmptyNode()
    of "dropIndex":
      result = newEmptyNode()
    of "addReference":
      # addReference(repo, table, refTable, ...) → removeReference(repo, table, refTable, ...)
      # Only copy positional args (indices 1-3), skip named args like onDelete:
      if stmt.len >= 4:
        result = newCall(newIdentNode("removeReference"), stmt[1], stmt[2], stmt[3])
      else:
        result = newEmptyNode()
    of "removeReference":
      result = newEmptyNode()
    of "addConstraint":
      # addConstraint(repo, table, name, def) → dropConstraint(repo, table, name)
      if stmt.len >= 5:
        result = newCall(newIdentNode("dropConstraint"), stmt[1], stmt[2], stmt[3])
      else:
        result = newEmptyNode()
    of "dropConstraint":
      result = newEmptyNode()
    else:
      result = newEmptyNode()
  else:
    result = newEmptyNode()

proc buildDownFromChange(changeBody: NimNode): NimNode =
  ## Генерира `down` тяло от `change` тяло чрез reverse на операциите.
  result = newStmtList()
  var reversed: seq[NimNode] = @[]
  for stmt in changeBody:
    let rev = reverseMigrationStmt(stmt)
    if rev.kind != nnkEmpty:
      reversed.add(rev)
  # down е reverse редът на операциите
  for i in countdown(reversed.high, 0):
    result.add(reversed[i])

macro necto_migration*(name: untyped, version: static[string], body: untyped): untyped =
  result = newStmtList()

  var upBody: NimNode = newEmptyNode()
  var downBody: NimNode = newEmptyNode()
  var changeBody: NimNode = newEmptyNode()

  for child in body:
    if child.kind in {nnkCall, nnkCommand}:
      let cmdName = $child[0]
      if cmdName == "up":
        upBody = child[1]
      elif cmdName == "down":
        downBody = child[1]
      elif cmdName == "change":
        changeBody = child[1]

  if changeBody.kind != nnkEmpty:
    upBody = changeBody
    downBody = buildDownFromChange(changeBody)

  if upBody.kind == nnkEmpty:
    error("Migration " & $name & " must have 'up', 'down', or 'change' block")

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

  # Compute checksum from up/down body repr
  let upRepr = if upBody.kind != nnkEmpty: upBody.repr else: ""
  let downRepr = if downBody.kind != nnkEmpty: downBody.repr else: ""
  let checksum = getMD5(upRepr & "::" & downRepr)

  # registerMigration(version, name, checksum, proc(): Migration = newTypeName())
  var lambdaBody = newStmtList()
  lambdaBody.add(nnkAsgn.newTree(
    newIdentNode("result"),
    newCall(newIdentNode("new" & $name))
  ))

  var regCall = newCall(
    newIdentNode("registerMigration"),
    newLit(version),
    newLit(typeNameStr),
    newLit(checksum),
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
