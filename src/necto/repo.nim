## Necto Repo
##
## Репозиторият е врата към базата данни. Всяко приложение дефинира
## поне един Repo чрез макрото `necto_repo`.
##
## Пример:
##   necto_repo AppRepo:
##     adapter PostgresAdapter
##     host "localhost"
##     database "my_app"
##     pool_size 10
##
## Употреба:
##   AppRepo.all(Query.fromSchema(User).where("age", Gt, "18"))
##   AppRepo.insert(userChangeset)

import std/[macros, options, strutils]
import ./adapters/base
import ./query
import ./schema
import ./changeset
import ./errors

export base, query, schema, changeset, errors

# --- Repo тип и публичен API ---

type
  RepoObj* = object of RootObj
    adapter*: Adapter

  Repo* = ref RepoObj

proc newRepo*(adapter: Adapter): Repo =
  Repo(adapter: adapter)

# --- Thread-local connection context (за транзакции) ---

var threadLocalConn {.threadvar.}: Connection

proc getConn*(repo: Repo): Connection =
  ## Взема връзка. Ако сме в транзакция, връща същата връзка.
  if threadLocalConn != nil:
    return threadLocalConn
  result = repo.adapter.connect()

proc releaseConn*(repo: Repo, conn: Connection) =
  ## Връща връзка в пула, освен ако е thread-local (транзакция).
  if threadLocalConn != nil:
    return
  repo.adapter.disconnect(conn)

# --- Raw SQL API (procs — не зависят от schema) ---

proc exec*(repo: Repo, sql: string, args: seq[string] = @[]) =
  ## Изпълнява raw SQL (DDL/DML) през адаптера.
  let conn = repo.getConn()
  try:
    repo.adapter.exec(conn, sql, args)
  finally:
    repo.releaseConn(conn)

proc queryRaw*(repo: Repo, sql: string, args: seq[string] = @[]): seq[DbRow] =
  ## Изпълнява raw SELECT и връща редовете.
  let conn = repo.getConn()
  try:
    repo.adapter.query(conn, sql, args)
  finally:
    repo.releaseConn(conn)

proc scalar*(repo: Repo, sql: string, args: seq[string] = @[]): string =
  ## Изпълнява raw SQL и връща скаларна стойност.
  let conn = repo.getConn()
  try:
    repo.adapter.scalar(conn, sql, args)
  finally:
    repo.releaseConn(conn)

# --- Query API (templates за lazy resolution на load/schemaMeta) ---

template all*[T](repo: Repo, q: Query[T]): seq[T] =
  ## Изпълнява SELECT заявка и връща seq от резултати.
  mixin load, schemaMeta
  block:
    let conn = repo.getConn()
    try:
      let bq = q.toBoundQuery()
      let rows = repo.adapter.query(conn, bq.sql, bq.args)
      var res: seq[T] = @[]
      for row in rows:
        res.add(load(row, T))
      res
    finally:
      repo.releaseConn(conn)

template one*[T](repo: Repo, q: Query[T]): Option[T] =
  ## Връща един резултат или none.
  mixin load
  block:
    let conn = repo.getConn()
    try:
      var q2 = q
      q2 = q2.limit(1)
      let bq = q2.toBoundQuery()
      let rows = repo.adapter.query(conn, bq.sql, bq.args)
      if rows.len > 0:
        some(load(rows[0], T))
      else:
        none(T)
    finally:
      repo.releaseConn(conn)

template count*[T](repo: Repo, q: Query[T]): int64 =
  ## Връща брой редове.
  mixin schemaMeta
  block:
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      var bq = q.toBoundQuery()
      # Заменяме SELECT ... с SELECT COUNT(*)
      let fromIdx = bq.sql.find(" FROM ")
      let countSql = "SELECT COUNT(*)" & bq.sql[fromIdx..^1]
      let val = repo.adapter.scalar(conn, countSql, bq.args)
      if val.len > 0:
        parseBiggestInt(val)
      else:
        0'i64
    finally:
      repo.releaseConn(conn)

# --- Write Helpers (вземат SchemaMeta като параметър; cs е auto за избягване на generic bound) ---

proc buildInsertSql(cs: auto, meta: SchemaMeta): (string, seq[string]) =
  ## Генерира INSERT SQL от changeset и schema metadata.
  var columns: seq[string] = @[]
  var placeholders: seq[string] = @[]
  var values: seq[string] = @[]
  var idx = 1

  for key, val in cs.changes.pairs():
    var fieldKnown = false
    for f in meta.fields:
      if f.name == key:
        fieldKnown = true
        break
    if not fieldKnown:
      continue
    var f: FieldMeta
    for fm in meta.fields:
      if fm.name == key:
        f = fm
        break
    if f.virtual:
      continue
    columns.add("\"" & f.dbColumn & "\"")
    placeholders.add("$" & $idx)
    values.add(val)
    inc idx

  for f in meta.fields:
    if f.isTimestamp and not cs.changes.hasKey(f.name):
      let nowStr = dumpValue(now())
      columns.add("\"" & f.dbColumn & "\"")
      placeholders.add("$" & $idx)
      values.add(nowStr)
      inc idx

  let sql = "INSERT INTO \"" & meta.tableName & "\" (" &
            columns.join(", ") & ") VALUES (" & placeholders.join(", ") & ")"
  result = (sql, values)

proc buildUpdateSql(cs: auto, meta: SchemaMeta): (string, seq[string]) =
  ## Генерира UPDATE SQL от changeset и schema metadata.
  var sets: seq[string] = @[]
  var values: seq[string] = @[]
  var idx = 1

  for key, val in cs.changes.pairs():
    var f: FieldMeta
    var found = false
    for fm in meta.fields:
      if fm.name == key:
        f = fm
        found = true
        break
    if not found or f.virtual or f.primaryKey:
      continue
    sets.add("\"" & f.dbColumn & "\" = $" & $idx)
    values.add(val)
    inc idx

  for f in meta.fields:
    if f.isTimestamp and f.name == "updated_at" and not cs.changes.hasKey(f.name):
      let nowStr = dumpValue(now())
      sets.add("\"" & f.dbColumn & "\" = $" & $idx)
      values.add(nowStr)
      inc idx

  var pkVal: string = ""
  for f in meta.fields:
    if f.primaryKey:
      if cs.changes.hasKey(f.name):
        pkVal = cs.changes[f.name]
      break

  if pkVal.len == 0:
    raise newException(ValidationError, "Cannot update without primary key value")

  values.add(pkVal)
  let whereClause = "\"" & meta.primaryKeyField & "\" = $" & $idx

  let sql = "UPDATE \"" & meta.tableName & "\" SET " &
            sets.join(", ") & " WHERE " & whereClause
  result = (sql, values)

proc buildDeleteSql(cs: auto, meta: SchemaMeta): (string, seq[string]) =
  ## Генерира DELETE SQL от changeset и schema metadata.
  var pkVal: string = ""
  for f in meta.fields:
    if f.primaryKey:
      if cs.changes.hasKey(f.name):
        pkVal = cs.changes[f.name]
      break

  if pkVal.len == 0:
    raise newException(ValidationError, "Cannot delete without primary key value")

  let sql = "DELETE FROM \"" & meta.tableName & "\" WHERE \"" &
            meta.primaryKeyField & "\" = $1"
  result = (sql, @[pkVal])

# --- Write API (templates) ---

template insert*[T](repo: Repo, cs: Changeset[T]): T =
  ## Вмъква запис от changeset.
  mixin schemaMeta, load
  block:
    if cs.isInvalid():
      raise newException(ValidationError, "Cannot insert invalid changeset")
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildInsertSql(cs, meta)
      let newId = repo.adapter.insertReturning(conn, sql, meta.primaryKeyField, args)
      let loadSql = "SELECT * FROM \"" & meta.tableName &
                    "\" WHERE \"" & meta.primaryKeyField & "\" = $1"
      let rows = repo.adapter.query(conn, loadSql, @[$newId])
      if rows.len > 0:
        load(rows[0], T)
      else:
        cs.data
    finally:
      repo.releaseConn(conn)

template update*[T](repo: Repo, cs: Changeset[T]): T =
  ## Актуализира запис от changeset.
  mixin schemaMeta, load
  block:
    if cs.isInvalid():
      raise newException(ValidationError, "Cannot update invalid changeset")
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildUpdateSql(cs, meta)
      repo.adapter.exec(conn, sql, args)
      var pkVal: string = ""
      for f in meta.fields:
        if f.primaryKey:
          if cs.changes.hasKey(f.name):
            pkVal = cs.changes[f.name]
          break
      let loadSql = "SELECT * FROM \"" & meta.tableName &
                    "\" WHERE \"" & meta.primaryKeyField & "\" = $1"
      let rows = repo.adapter.query(conn, loadSql, @[pkVal])
      if rows.len > 0:
        load(rows[0], T)
      else:
        cs.data
    finally:
      repo.releaseConn(conn)

template delete*[T](repo: Repo, cs: Changeset[T]): T =
  ## Изтрива запис от changeset.
  mixin schemaMeta
  block:
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildDeleteSql(cs, meta)
      repo.adapter.exec(conn, sql, args)
      cs.data
    finally:
      repo.releaseConn(conn)

# --- Bang версии (вдигат грешка) ---

proc `insert!`*[T](repo: Repo, cs: Changeset[T]): T =
  if cs.isInvalid():
    raise newException(ValidationError, "Changeset is invalid")
  result = repo.insert(cs)

proc `update!`*[T](repo: Repo, cs: Changeset[T]): T =
  if cs.isInvalid():
    raise newException(ValidationError, "Changeset is invalid")
  result = repo.update(cs)

proc `delete!`*[T](repo: Repo, cs: Changeset[T]): T =
  result = repo.delete(cs)

# --- Transaction API ---

proc transaction*(repo: Repo, body: proc()) =
  ## Изпълнява блок в транзакция.
  ## Всички repo операции вътре в body ползват една и съща връзка.
  let conn = repo.adapter.connect()
  let prevConn = threadLocalConn
  threadLocalConn = conn
  try:
    repo.adapter.beginTransaction(conn)
    body()
    repo.adapter.commitTransaction(conn)
  except:
    repo.adapter.rollbackTransaction(conn)
    raise
  finally:
    threadLocalConn = prevConn
    repo.adapter.disconnect(conn)

# --- Макро за дефиниране на Repo ---

macro necto_repo*(name: untyped, body: untyped): untyped =
  ## Дефинира нов Repo модул/тип със свой адаптер.
  result = newStmtList()

  var adapterType = newIdentNode("PostgresAdapter")
  var hostVal = newLit("localhost")
  var portVal = newLit(5432)
  var userVal = newLit("postgres")
  var passVal = newLit("")
  var dbVal = newLit("postgres")
  var poolSizeVal = newLit(10)

  for child in body:
    if child.kind in {nnkCall, nnkCommand}:
      let key = $child[0]
      case key
      of "adapter":
        adapterType = child[1]
      of "host":
        hostVal = child[1]
      of "port":
        portVal = child[1]
      of "user":
        userVal = child[1]
      of "password":
        passVal = child[1]
      of "database":
        dbVal = child[1]
      of "pool_size", "poolSize":
        poolSizeVal = child[1]

  let typeName = name
  let procName = newIdentNode("new" & $name)
  let instanceName = newIdentNode(toLowerAscii($name) & "Instance")

  result.add(newTree(nnkTypeSection,
    newTree(nnkTypeDef,
      newTree(nnkPostfix, newIdentNode("*"), typeName),
      newEmptyNode(),
      newTree(nnkRefTy,
        newTree(nnkObjectTy,
          newEmptyNode(),
          newTree(nnkOfInherit, newIdentNode("Repo")),
          newTree(nnkRecList)
        )
      )
    )
  ))

  result.add(quote do:
    proc `procName`*(): `typeName` =
      var adapter = newPostgresAdapter(
        `hostVal`, `userVal`, `passVal`, `dbVal`,
        port = `portVal`,
        poolSize = `poolSizeVal`
      )
      result = `typeName`(adapter: adapter)

    let `instanceName`* = `procName`()
  )
