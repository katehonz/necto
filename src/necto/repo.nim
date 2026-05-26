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

import std/[macros, options, strutils, tables]
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
  block:
    let conn = repo.getConn()
    try:
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

# --- Auto-preload macros ---

macro allWithPreload*(repoArg: Repo, qArg: typed, preloads: varargs[string]): untyped =
  ## Изпълнява SELECT и автоматично preload-ва асоциациите.
  ## Пример: repo.allWithPreload(Query.fromSchema(Post), "author", "comments")
  let qType = getTypeInst(qArg)
  if qType.kind != nnkBracketExpr:
    error("Expected Query[T], got " & repr(qType))

  let repoIdent = newIdentNode("repo")
  let resIdent = newIdentNode("res")

  var preloadStmts = newStmtList()
  for p in preloads:
    let assocName = newLit($p)
    preloadStmts.add(newCall(newIdentNode("preloadAssoc"), assocName, repoIdent, resIdent))

  var blockBody = newStmtList()
  blockBody.add(newTree(nnkLetSection, newTree(nnkIdentDefs, repoIdent, newEmptyNode(), repoArg)))
  blockBody.add(newTree(nnkVarSection, newTree(nnkIdentDefs, resIdent, newEmptyNode(),
    newCall(newTree(nnkDotExpr, repoIdent, newIdentNode("all")), qArg))))
  blockBody.add(preloadStmts)
  blockBody.add(resIdent)

  result = newTree(nnkBlockStmt, newEmptyNode(), blockBody)

macro oneWithPreload*(repoArg: Repo, qArg: typed, preloads: varargs[string]): untyped =
  ## Връща един резултат с автоматичен preload.
  let qType = getTypeInst(qArg)
  if qType.kind != nnkBracketExpr:
    error("Expected Query[T], got " & repr(qType))
  let parentType = qType[1]

  let repoIdent = newIdentNode("repo")
  let resSeqIdent = newIdentNode("resSeq")
  let maybeIdent = newIdentNode("maybe")

  var preloadStmts = newStmtList()
  for p in preloads:
    let assocName = newLit($p)
    preloadStmts.add(newCall(newIdentNode("preloadAssoc"), assocName, repoIdent, resSeqIdent))

  var blockBody = newStmtList()
  blockBody.add(newTree(nnkLetSection, newTree(nnkIdentDefs, repoIdent, newEmptyNode(), repoArg)))

  # var q2 = q; q2 = q2.limit(1)
  let q2Ident = newIdentNode("q2")
  blockBody.add(newTree(nnkVarSection, newTree(nnkIdentDefs, q2Ident, newEmptyNode(), qArg)))
  blockBody.add(newTree(nnkAsgn,
    newTree(nnkDotExpr, q2Ident, newIdentNode("limit")),
    newLit(1)))

  # var resSeq: seq[ParentType] = @[]
  blockBody.add(newTree(nnkVarSection, newTree(nnkIdentDefs, resSeqIdent,
    newTree(nnkBracketExpr, newIdentNode("seq"), parentType),
    newCall(newIdentNode("@"), newTree(nnkBracket)))))

  # let maybe = repo.one(q2)
  blockBody.add(newTree(nnkLetSection, newTree(nnkIdentDefs, maybeIdent, newEmptyNode(),
    newCall(newTree(nnkDotExpr, repoIdent, newIdentNode("one")), q2Ident))))

  # if maybe.isSome: resSeq.add(maybe.get); preloadStmts; some(resSeq[0]) else: none(ParentType)
  var ifBody = newStmtList()
  ifBody.add(newCall(newTree(nnkDotExpr, resSeqIdent, newIdentNode("add")),
    newTree(nnkDotExpr, maybeIdent, newIdentNode("get"))))
  ifBody.add(preloadStmts)
  ifBody.add(newCall(newIdentNode("some"), newTree(nnkBracketExpr, resSeqIdent, newLit(0))))

  let elseBody = newCall(newIdentNode("none"), parentType)

  blockBody.add(newTree(nnkIfStmt,
    newTree(nnkElifBranch,
      newTree(nnkDotExpr, maybeIdent, newIdentNode("isSome")),
      ifBody),
    newTree(nnkElse, elseBody)))

  result = newTree(nnkBlockStmt, newEmptyNode(), blockBody)

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

# --- Constraint Error Handling (Ecto pattern) ---

proc parseConstraintName*(errorMsg: string): string =
  ## Извлича името на constraint от PostgreSQL грешка.
  let idx = errorMsg.find("violates ")
  if idx >= 0:
    let after = errorMsg[idx + 9 .. ^1]
    let start = after.find('"')
    let endPos = after.find('"', start + 1)
    if start >= 0 and endPos > start:
      return after[start + 1 .. endPos - 1]
  result = ""

proc handleConstraintError*[T](cs: var Changeset[T], errorMsg: string) =
  ## Анализира DB грешка и попълва changeset errors ако има
  ## регистрирани constraints за засегнатото поле.
  let constraintName = parseConstraintName(errorMsg)
  if constraintName.len == 0:
    return

  let isUniqueViolation = errorMsg.contains("unique") or errorMsg.contains("23505")
  let isFkViolation = errorMsg.contains("foreign key") or errorMsg.contains("23503")

  if isUniqueViolation or isFkViolation:
    for field, metas in cs.constraints.pairs():
      for m in metas:
        if isUniqueViolation and m.kind == ckUnique:
          cs.addError(field, m.message)
          return
        elif isFkViolation and m.kind == ckForeignKey:
          cs.addError(field, m.message)
          return

# --- Write API (templates) ---

template insert*[T](repo: Repo, cs: Changeset[T]): T =
  ## Вмъква запис от changeset.
  ## Ако DB върне constraint violation (unique/fk), грешката се
  ## попълва в changeset и се вдига ConstraintError.
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
    except DatabaseError as e:
      var cs2 = cs
      handleConstraintError(cs2, e.msg)
      if cs2.isInvalid():
        var ce = new(ConstraintError)
        ce.msg = e.msg
        ce.constraintName = ""
        raise ce
      raise
    finally:
      repo.releaseConn(conn)

template insert_all*(repo: Repo, changesets: auto): auto =
  ## Batch insert на множество changesets.
  ## Връща seq от заредените записи (чрез RETURNING *).
  ## Всички changesets трябва да са cast-нати с еднакви полета.
  mixin schemaMeta, load
  block:
    if changesets.len == 0:
      @[]
    else:
      type ItemType = typeof(changesets[0].data)
      # Проверка за невалидни changesets
      for cs in changesets:
        if cs.isInvalid():
          raise newException(ValidationError, "Cannot insert invalid changeset in batch")
      let conn = repo.getConn()
      try:
        let meta = schemaMeta(ItemType)

        # --- Build batch INSERT SQL inline ---
        var columns: seq[string] = @[]
        var allValues: seq[string] = @[]
        var idx = 1

        let firstCs = changesets[0]
        for key, val in firstCs.changes.pairs():
          var fieldKnown = false
          var f: FieldMeta
          for fm in meta.fields:
            if fm.name == key:
              f = fm
              fieldKnown = true
              break
          if not fieldKnown or f.virtual:
            continue
          columns.add("\"" & f.dbColumn & "\"")

        var timestampCols: seq[FieldMeta] = @[]
        for f in meta.fields:
          if f.isTimestamp and not firstCs.changes.hasKey(f.name):
            timestampCols.add(f)
            columns.add("\"" & f.dbColumn & "\"")

        var rowGroups: seq[string] = @[]
        for cs in changesets:
          var rowPlaceholders: seq[string] = @[]
          for key, val in cs.changes.pairs():
            var fieldKnown = false
            for f in meta.fields:
              if f.name == key:
                fieldKnown = true
                break
            if not fieldKnown:
              continue
            rowPlaceholders.add("$" & $idx)
            allValues.add(val)
            inc idx
          for f in timestampCols:
            rowPlaceholders.add("$" & $idx)
            allValues.add(dumpValue(now()))
            inc idx
          rowGroups.add("(" & rowPlaceholders.join(", ") & ")")

        let sql = "INSERT INTO \"" & meta.tableName & "\" (" &
                  columns.join(", ") & ") VALUES " &
                  rowGroups.join(", ") & " RETURNING *"
        # --------------------------------------

        let rows = repo.adapter.query(conn, sql, allValues)
        var res: seq[ItemType] = @[]
        for row in rows:
          res.add(load(row, ItemType))
        res
      except DatabaseError as e:
        var ce = new(ConstraintError)
        ce.msg = e.msg
        ce.constraintName = ""
        raise ce
      finally:
        repo.releaseConn(conn)

proc renumberPlaceholders(sql: string, offset: int): string =
  ## Преименува $N placeholders с offset.
  ## Пример: renumberPlaceholders("WHERE x = $1 AND y = $2", 2) → "WHERE x = $3 AND y = $4"
  result = sql
  var i = result.len - 1
  while i >= 0:
    if result[i] == '$':
      var j = i + 1
      var num = 0
      while j < result.len and result[j] in {'0'..'9'}:
        num = num * 10 + (result[j].ord - '0'.ord)
        inc j
      if num > 0:
        let newNum = num + offset
        result = result[0..<i] & "$" & $newNum & result[j..^1]
    dec i

template update_all*[T](repo: Repo, q: Query[T], changes: Table[string, string]): int64 =
  ## Batch update на записи отговарящи на Query.
  ## Връща брой засегнати редове.
  ## Пример: repo.update_all(Query.fromSchema(User).where("active", Eq, "false"), {"active": "true"}.toTable)
  mixin schemaMeta
  block:
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      var sets: seq[string] = @[]
      var values: seq[string] = @[]
      var idx = 1

      for key, val in changes.pairs():
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

      # Автоматичен updated_at
      for f in meta.fields:
        if f.isTimestamp and f.name == "updated_at":
          sets.add("\"" & f.dbColumn & "\" = $" & $idx)
          values.add(dumpValue(now()))
          inc idx
          break

      let bq = q.toBoundQuery()
      # Заменяме SELECT ... с UPDATE ... SET ... WHERE ...
      let fromIdx = bq.sql.find(" FROM ")
      let whereIdx = bq.sql.find(" WHERE ")
      var tablePart = if fromIdx >= 0: bq.sql[fromIdx + 6 ..< (if whereIdx >= 0: whereIdx else: bq.sql.len)] else: meta.tableName
      if tablePart.startsWith("\"") and tablePart.endsWith("\""):
        tablePart = tablePart[1 ..< tablePart.len - 1]
      
      var sql = "UPDATE \"" & tablePart & "\" SET " & sets.join(", ")
      if whereIdx >= 0:
        let whereSql = renumberPlaceholders(bq.sql[whereIdx..^1], idx - 1)
        sql.add(" " & whereSql)
        for a in bq.args:
          values.add(a)
      
      repo.adapter.execAffected(conn, sql, values)
    finally:
      repo.releaseConn(conn)

template delete_all*[T](repo: Repo, q: Query[T]): int64 =
  ## Изтрива всички записи отговарящи на Query.
  ## Връща брой изтрити редове.
  ## Пример: repo.delete_all(fromSchema(User).where("active", Eq, "false"))
  mixin schemaMeta
  block:
    let conn = repo.getConn()
    try:
      let meta = schemaMeta(T)
      let bq = q.toBoundQuery()
      let fromIdx = bq.sql.find(" FROM ")
      let whereIdx = bq.sql.find(" WHERE ")
      var tablePart = if fromIdx >= 0: bq.sql[fromIdx + 6 ..< (if whereIdx >= 0: whereIdx else: bq.sql.len)] else: meta.tableName
      if tablePart.startsWith("\"") and tablePart.endsWith("\""):
        tablePart = tablePart[1 ..< tablePart.len - 1]
      
      var sql = "DELETE FROM \"" & tablePart & "\""
      var args: seq[string] = @[]
      if whereIdx >= 0:
        sql.add(" " & bq.sql[whereIdx..^1])
        args = bq.args
      
      repo.adapter.execAffected(conn, sql, args)
    finally:
      repo.releaseConn(conn)

template update*[T](repo: Repo, cs: Changeset[T]): T =
  ## Актуализира запис от changeset.
  ## Ако DB върне constraint violation, обработва се аналогично на insert.
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
    except DatabaseError as e:
      var cs2 = cs
      handleConstraintError(cs2, e.msg)
      if cs2.isInvalid():
        var ce = new(ConstraintError)
        ce.msg = e.msg
        ce.constraintName = parseConstraintName(e.msg)
        raise ce
      raise
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
    try:
      repo.adapter.rollbackTransaction(conn)
    except:
      discard
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
