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

import std/[macros, options, strutils, tables, algorithm, times]
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
    readAdapter*: Adapter

  Repo* = ref RepoObj

proc newRepo*(adapter: Adapter; readAdapter: Adapter = nil): Repo =
  Repo(adapter: adapter, readAdapter: if readAdapter != nil: readAdapter else: adapter)

# --- Thread-local connection context (за транзакции) ---

var threadLocalConn {.threadvar.}: Connection
var savepointStack {.threadvar.}: seq[string]

proc inTransaction*(repo: Repo): bool =
  ## Връща true ако сме в транзакция.
  threadLocalConn != nil

proc getWriteConn*(repo: Repo): Connection =
  ## Взема write връзка. Ако сме в транзакция, връща същата връзка.
  if threadLocalConn != nil:
    return threadLocalConn
  result = repo.adapter.connect()

proc getReadConn*(repo: Repo): Connection =
  ## Взема read връзка. Ако сме в транзакция, връща същата връзка (write).
  if threadLocalConn != nil:
    return threadLocalConn
  let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
  result = a.connect()

proc releaseConn*(repo: Repo, conn: Connection; adapter: Adapter = nil) =
  ## Връща връзка в пула, освен ако е thread-local (транзакция).
  if threadLocalConn != nil:
    return
  let a = if adapter != nil: adapter else: repo.adapter
  a.disconnect(conn)

# --- Raw SQL API (procs — не зависят от schema) ---

proc exec*(repo: Repo, sql: string, args: seq[string] = @[]) =
  ## Изпълнява raw SQL (DDL/DML) през write адаптера.
  let conn = repo.getWriteConn()
  try:
    repo.adapter.exec(conn, sql, args)
  finally:
    repo.releaseConn(conn, repo.adapter)

proc queryRaw*(repo: Repo, sql: string, args: seq[string] = @[]): seq[DbRow] =
  ## Изпълнява raw SELECT през read адаптера.
  let conn = repo.getReadConn()
  let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
  try:
    a.query(conn, sql, args)
  finally:
    repo.releaseConn(conn, a)

proc scalar*(repo: Repo, sql: string, args: seq[string] = @[]): string =
  ## Изпълнява raw SQL през read адаптера и връща скалар.
  let conn = repo.getReadConn()
  let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
  try:
    a.scalar(conn, sql, args)
  finally:
    repo.releaseConn(conn, a)

proc poolMetrics*(repo: Repo): PoolMetrics =
  ## Връща метрики за connection pool-а.
  repo.adapter.poolMetrics()

# --- Query API (templates за lazy resolution на load/schemaMeta) ---

template all*[T](repo: Repo, q: Query[T]): seq[T] =
  ## Изпълнява SELECT заявка и връща seq от резултати.
  ## Ако Query има `.preload("...")`, асоциациите се зареждат автоматично.
  mixin load, schemaMeta
  block:
    let conn = repo.getReadConn()
    let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
    try:
      let bq = q.toBoundQuery()
      let rows = a.query(conn, bq.sql, bq.args)
      var res: seq[T] = @[]
      for row in rows:
        res.add(load(row, T))
      if q.preloadAssocs.len > 0:
        when compiles(autoPreloadAssocs(repo, res, q.preloadAssocs)):
          autoPreloadAssocs(repo, res, q.preloadAssocs)
      res
    finally:
      repo.releaseConn(conn, a)

template one*[T](repo: Repo, q: Query[T]): Option[T] =
  ## Връща един резултат или none.
  ## Ако Query има `.preload("...")`, асоциациите се зареждат автоматично.
  mixin load
  block:
    let conn = repo.getReadConn()
    let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
    try:
      var q2 = q
      q2 = q2.limit(1)
      let bq = q2.toBoundQuery()
      let rows = a.query(conn, bq.sql, bq.args)
      if rows.len > 0:
        var res = @[load(rows[0], T)]
        if q2.preloadAssocs.len > 0:
          when compiles(autoPreloadAssocs(repo, res, q2.preloadAssocs)):
            autoPreloadAssocs(repo, res, q2.preloadAssocs)
        some(res[0])
      else:
        none(T)
    finally:
      repo.releaseConn(conn, a)

template count*[T](repo: Repo, q: Query[T]): int64 =
  ## Връща брой редове.
  ## Не работи с GROUP BY — при GROUP BY използвайте подзаявка или `repo.all` с агрегати.
  block:
    let conn = repo.getReadConn()
    let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
    try:
      var bq = q.toBoundQuery()
      if bq.sql.find(" GROUP BY ") >= 0:
        raise newException(QueryError,
          "count() does not support GROUP BY. Use a subquery or aggregate select instead.")
      # Заменяме SELECT ... с SELECT COUNT(*)
      let fromIdx = bq.sql.find(" FROM ")
      let countSql = "SELECT COUNT(*)" & bq.sql[fromIdx..^1]
      let val = a.scalar(conn, countSql, bq.args)
      if val.len > 0:
        parseBiggestInt(val)
      else:
        0'i64
    finally:
      repo.releaseConn(conn, a)

# --- Streaming (cursor-based) ---

type
  StreamIterator*[T] = object
    ## Cursor-based iterator за големи резултати.
    ## Задържа една връзка и една транзакция за целия stream.
    conn: Connection
    adapter: Adapter
    cursorName: string
    batchSize: int
    bq: BoundQuery
    buffer: seq[T]
    bufferIdx: int
    finished: bool

proc next*[T](it: var StreamIterator[T]): Option[T] =
  ## Връща следващия запис от stream-а или none ако stream-ът е изчерпан.
  mixin load
  if it.finished:
    return none(T)

  # Fetch next batch ако buffer-ът е празен
  if it.bufferIdx >= it.buffer.len:
    it.bufferIdx = 0
    it.buffer = @[]
    let rows = it.adapter.fetchCursor(it.conn, it.cursorName, it.batchSize)
    if rows.len == 0:
      it.finished = true
      return none(T)
    for row in rows:
      it.buffer.add(load(row, T))

  if it.bufferIdx < it.buffer.len:
    result = some(it.buffer[it.bufferIdx])
    inc it.bufferIdx
  else:
    it.finished = true
    result = none(T)



template stream*[T](repo: Repo, q: Query[T], batchSz: int = 100): StreamIterator[T] =
  ## Създава cursor-based stream за Query.
  ## Stream-ът задържа една връзка и една транзакция.
  ## Задължително извикайте `close()` или използвайте `forStream` template.
  mixin schemaMeta, load
  block:
    let meta = schemaMeta(T)
    let a = if repo.readAdapter != nil: repo.readAdapter else: repo.adapter
    let conn = repo.getReadConn()
    let bs = batchSz
    var iter: StreamIterator[T]
    iter.conn = conn
    iter.adapter = a
    iter.batchSize = bs
    iter.bufferIdx = 0
    iter.finished = false
    iter.bq = q.toBoundQuery()
    let uniqueId = epochTime().int64
    iter.cursorName = "necto_cursor_" & meta.tableName & "_" & $uniqueId

    try:
      a.beginTransaction(conn)
      let cursorSql = "DECLARE \"" & iter.cursorName & "\" CURSOR FOR " & iter.bq.sql
      a.exec(conn, cursorSql, iter.bq.args)
    except:
      repo.releaseConn(conn, a)
      raise

    iter

proc close*[T](it: var StreamIterator[T]) =
  ## Затваря курсора и освобождава връзката.
  if it.conn == nil:
    return
  try:
    it.adapter.exec(it.conn, "CLOSE \"" & it.cursorName & "\"")
    it.adapter.commitTransaction(it.conn)
  except:
    discard
  it.adapter.disconnect(it.conn)
  it.conn = nil

template forStream*[T](repo: Repo, q: Query[T], varName: untyped, body: untyped) =
  ## Iterate over a Query result stream. Closes automatically.
  ## Пример:
  ##   forStream(repo, fromSchema(User).where("age", Gte, "18"), user):
  ##     echo user.name
  block:
    var iter = repo.stream(q)
    try:
      while true:
        let varNameOpt = iter.next()
        if varNameOpt.isNone: break
        let varName = varNameOpt.get
        body
    finally:
      iter.close()

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
    let cacheVar = newIdentNode("necto_preload_" & $p)
    preloadStmts.add(newTree(nnkLetSection, newTree(nnkIdentDefs, cacheVar, newEmptyNode(),
      newCall(newIdentNode("preloadAssoc"), assocName, repoIdent, resIdent))))

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
    let cacheVar = newIdentNode("necto_preload_" & $p)
    preloadStmts.add(newTree(nnkLetSection, newTree(nnkIdentDefs, cacheVar, newEmptyNode(),
      newCall(newIdentNode("preloadAssoc"), assocName, repoIdent, resSeqIdent))))

  var blockBody = newStmtList()
  blockBody.add(newTree(nnkLetSection, newTree(nnkIdentDefs, repoIdent, newEmptyNode(), repoArg)))

  # var q2 = q; q2 = q2.limit(1)
  let q2Ident = newIdentNode("q2")
  blockBody.add(newTree(nnkVarSection, newTree(nnkIdentDefs, q2Ident, newEmptyNode(), qArg)))
  blockBody.add(newTree(nnkAsgn, q2Ident,
    newCall(newTree(nnkDotExpr, q2Ident, newIdentNode("limit")), newLit(1))))

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

  let elseBody = newCall(newTree(nnkBracketExpr, newIdentNode("none"), parentType))

  blockBody.add(newTree(nnkIfStmt,
    newTree(nnkElifBranch,
      newTree(nnkDotExpr, maybeIdent, newIdentNode("isSome")),
      ifBody),
    newTree(nnkElse, elseBody)))

  result = newTree(nnkBlockStmt, newEmptyNode(), blockBody)

# --- Write Helpers (вземат SchemaMeta като параметър; cs е auto за избягване на generic bound) ---

type
  OnConflictKind* = enum
    ocNone,        ## Без ON CONFLICT
    ocDoNothing,   ## ON CONFLICT DO NOTHING
    ocDoUpdate     ## ON CONFLICT DO UPDATE SET ...

  OnConflict* = object
    kind*: OnConflictKind
    conflictTarget*: string        ## Колона(и) за conflict, напр. "id" или "id, email"
    updateFields*: seq[string]     ## Полета за UPDATE при ocDoUpdate (празно = всички)

proc doNothing*(): OnConflict =
  ## Създава ON CONFLICT DO NOTHING.
  OnConflict(kind: ocDoNothing)

proc doUpdate*(conflictTarget: string; fields: seq[string] = @[]): OnConflict =
  ## Създава ON CONFLICT (target) DO UPDATE SET fields...
  ## Ако fields е празно, обновяват се всички полета (без PK и timestamps).
  OnConflict(kind: ocDoUpdate, conflictTarget: conflictTarget, updateFields: fields)

proc buildInsertSql(cs: auto, meta: SchemaMeta; onConflict: OnConflict = OnConflict(kind: ocNone)): (string, seq[string]) =
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

  var sql = "INSERT INTO \"" & meta.tableName & "\" (" &
            columns.join(", ") & ") VALUES (" & placeholders.join(", ") & ")"

  # --- ON CONFLICT ---
  if onConflict.kind == ocDoNothing:
    if onConflict.conflictTarget.len > 0:
      sql.add(" ON CONFLICT (" & onConflict.conflictTarget & ") DO NOTHING")
    else:
      sql.add(" ON CONFLICT DO NOTHING")
  elif onConflict.kind == ocDoUpdate:
    let target = if onConflict.conflictTarget.len > 0: onConflict.conflictTarget else: meta.primaryKeyField
    sql.add(" ON CONFLICT (" & target & ") DO UPDATE SET ")
    var updates: seq[string] = @[]
    for f in meta.fields:
      if f.primaryKey or f.virtual:
        continue
      if onConflict.updateFields.len > 0 and f.name notin onConflict.updateFields:
        continue
      if f.isTimestamp and f.name == "updated_at":
        updates.add("\"" & f.dbColumn & "\" = EXCLUDED.\"" & f.dbColumn & "\"")
      elif cs.changes.hasKey(f.name) or f.isTimestamp:
        updates.add("\"" & f.dbColumn & "\" = EXCLUDED.\"" & f.dbColumn & "\"")
    if updates.len == 0:
      # Fallback: update всички non-PK колони от changes
      for key, val in cs.changes.pairs():
        for f in meta.fields:
          if f.name == key and not f.primaryKey and not f.virtual:
            updates.add("\"" & f.dbColumn & "\" = EXCLUDED.\"" & f.dbColumn & "\"")
            break
    sql.add(updates.join(", "))

  result = (sql, values)

template buildUpdateSql(cs: auto, meta: SchemaMeta): (string, seq[string]) =
  ## Генерира UPDATE SQL от changeset и schema metadata.
  ## Template за да резолвира `getFieldValRuntime` (generated per-schema).
  mixin getFieldValRuntime
  block:
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

    # Also look up PK from the original data if not in changes
    if pkVal.len == 0:
      for f in meta.fields:
        if f.primaryKey:
          try:
            pkVal = getFieldValRuntime(cs.data, f.name)
          except:
            discard
          break

    if pkVal.len == 0:
      raise newException(ValidationError, "Cannot update without primary key value")

    # No changes to apply — return empty SQL to signal skip
    if sets.len == 0:
      ("", @[])
    else:
      values.add(pkVal)
      let whereClause = "\"" & meta.primaryKeyField & "\" = $" & $idx
      let sql = "UPDATE \"" & meta.tableName & "\" SET " &
                sets.join(", ") & " WHERE " & whereClause
      (sql, values)

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

proc buildSoftDeleteSql(cs: auto, meta: SchemaMeta): (string, seq[string]) =
  ## Генерира UPDATE SQL за soft delete.
  var pkVal: string = ""
  for f in meta.fields:
    if f.primaryKey:
      if cs.changes.hasKey(f.name):
        pkVal = cs.changes[f.name]
      break

  if pkVal.len == 0:
    raise newException(ValidationError, "Cannot soft-delete without primary key value")

  let sql = "UPDATE \"" & meta.tableName & "\" SET \"deleted_at\" = NOW() WHERE \"" &
            meta.primaryKeyField & "\" = $1 AND \"deleted_at\" IS NULL"
  result = (sql, @[pkVal])

# --- Constraint Error Handling (Ecto pattern) ---

proc parseConstraintName*(errorMsg: string): string =
  ## Извлича името на constraint от PostgreSQL грешка.
  let idx = errorMsg.find("violates ")
  if idx >= 0:
    let after = errorMsg[idx + 8 .. ^1]
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
    let conn = repo.getWriteConn()
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
      repo.releaseConn(conn, repo.adapter)

template insert*[T](repo: Repo, cs: Changeset[T], onConflict: OnConflict): T =
  ## Вмъква запис с ON CONFLICT обработка.
  ## `onConflict` може да е `doNothing()` или `doUpdate("id", @["name", "email"])`.
  mixin schemaMeta, load
  block:
    if cs.isInvalid():
      raise newException(ValidationError, "Cannot insert invalid changeset")
    let conn = repo.getWriteConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildInsertSql(cs, meta, onConflict)
      var pkVal = ""
      for f in meta.fields:
        if f.primaryKey:
          if cs.changes.hasKey(f.name):
            pkVal = cs.changes[f.name]
          else:
            try:
              pkVal = getFieldValRuntime(cs.data, f.name)
            except:
              discard
          break
      var hasRealPk = pkVal.len > 0
      if hasRealPk:
        # Проверяваме дали PK е валиден (не default стойност като "0")
        for f in meta.fields:
          if f.primaryKey and (f.nimType == "int64" or f.nimType == "int" or f.nimType == "int16"):
            try:
              if parseBiggestInt(pkVal) <= 0:
                hasRealPk = false
            except ValueError:
              discard
            break
      if hasRealPk:
        # При upsert знаем PK и можем да load-нем директно
        repo.adapter.exec(conn, sql, args)
        let loadSql = "SELECT * FROM \"" & meta.tableName &
                      "\" WHERE \"" & meta.primaryKeyField & "\" = $1"
        let rows = repo.adapter.query(conn, loadSql, @[pkVal])
        if rows.len > 0:
          load(rows[0], T)
        else:
          cs.data
      else:
        # Не знаем PK - използваме insertReturning
        var newId: int64 = 0
        try:
          newId = repo.adapter.insertReturning(conn, sql, meta.primaryKeyField, args)
        except DatabaseError as e:
          if onConflict.kind == ocDoNothing and e.msg.contains("no rows returned"):
            # DO NOTHING — връщаме nil/pointer който извикващият трябва да обработи
            newId = 0
          else:
            raise
        if newId > 0:
          let loadSql = "SELECT * FROM \"" & meta.tableName &
                        "\" WHERE \"" & meta.primaryKeyField & "\" = $1"
          let rows = repo.adapter.query(conn, loadSql, @[$newId])
          if rows.len > 0:
            load(rows[0], T)
          else:
            cs.data
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
      repo.releaseConn(conn, repo.adapter)

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
      let conn = repo.getWriteConn()
      try:
        let meta = schemaMeta(ItemType)

        # --- Build batch INSERT SQL inline ---
        var columns: seq[string] = @[]
        var allValues: seq[string] = @[]
        var idx = 1

        let firstCs = changesets[0]
        # Collect column names in deterministic (sorted) order
        var orderedFields: seq[(string, FieldMeta)] = @[]
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
          orderedFields.add((key, f))
          columns.add("\"" & f.dbColumn & "\"")

        # Sort by field name for deterministic ordering
        orderedFields.sort do (a, b: (string, FieldMeta)) -> int:
          cmp(a[0], b[0])

        # Rebuild columns from sorted order
        columns = @[]
        for pair in orderedFields:
          columns.add("\"" & pair[1].dbColumn & "\"")

        var timestampCols: seq[FieldMeta] = @[]
        for f in meta.fields:
          if f.isTimestamp and not firstCs.changes.hasKey(f.name):
            timestampCols.add(f)
            columns.add("\"" & f.dbColumn & "\"")

        # Build a set of valid fields from firstCs for quick lookup
        var validFields: seq[string] = @[]
        for pair in orderedFields:
          validFields.add(pair[0])
        for f in timestampCols:
          validFields.add(f.name)

        var rowGroups: seq[string] = @[]
        for cs in changesets:
          var rowPlaceholders: seq[string] = @[]
          # Use sorted field order, not hash table iteration
          for pair in orderedFields:
            let key = pair[0]
            if cs.changes.hasKey(key):
              rowPlaceholders.add("$" & $idx)
              allValues.add(cs.changes[key])
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
        repo.releaseConn(conn, repo.adapter)

template insert_all*[T](repo: Repo, typ: typedesc[T], entries: seq[Table[string, string]]): seq[T] =
  ## Batch insert на raw entries без changeset.
  ## Валидира стойностите спрямо schema meta и връща заредените записи.
  ## Пример:
  ##   repo.insert_all(User, @[{"name": "Ivan"}.toTable, {"name": "Maria"}.toTable])
  mixin schemaMeta, load, castToDb
  block:
    if entries.len == 0:
      @[]
    else:
      let conn = repo.getWriteConn()
      try:
        let meta = schemaMeta(T)

        # Определяме валидните полета (без auto_increment PK, виртуални и timestamps)
        var validFields: seq[FieldMeta] = @[]
        for f in meta.fields:
          if f.virtual or f.isTimestamp:
            continue
          if f.primaryKey and f.autoIncrement:
            continue
          validFields.add(f)

        # Сортираме за детерминистична поръчка
        validFields.sort do (a, b: FieldMeta) -> int:
          cmp(a.name, b.name)

        # Строим колоните
        var columns: seq[string] = @[]
        for f in validFields:
          columns.add("\"" & f.dbColumn & "\"")

        var allValues: seq[string] = @[]
        var idx = 1
        var rowGroups: seq[string] = @[]

        for entry in entries:
          var rowPlaceholders: seq[string] = @[]
          for f in validFields:
            let rawVal = if entry.hasKey(f.name): entry[f.name] else: ""
            let casted = castToDb(rawVal, f.nimType)
            rowPlaceholders.add("$" & $idx)
            allValues.add(casted)
            inc idx
          rowGroups.add("(" & rowPlaceholders.join(", ") & ")")

        let sql = "INSERT INTO \"" & meta.tableName & "\" (" &
                  columns.join(", ") & ") VALUES " &
                  rowGroups.join(", ") & " RETURNING *"

        let rows = repo.adapter.query(conn, sql, allValues)
        var res: seq[T] = @[]
        for row in rows:
          res.add(load(row, T))
        res
      except DatabaseError as e:
        var ce = new(ConstraintError)
        ce.msg = e.msg
        ce.constraintName = ""
        raise ce
      finally:
        repo.releaseConn(conn, repo.adapter)

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
    let conn = repo.getWriteConn()
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
      repo.releaseConn(conn, repo.adapter)

template delete_all*[T](repo: Repo, q: Query[T]): int64 =
  ## Изтрива всички записи отговарящи на Query.
  ## Връща брой изтрити редове.
  ## Пример: repo.delete_all(fromSchema(User).where("active", Eq, "false"))
  mixin schemaMeta
  block:
    let conn = repo.getWriteConn()
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
      repo.releaseConn(conn, repo.adapter)

template update*[T](repo: Repo, cs: Changeset[T]): T =
  ## Актуализира запис от changeset.
  ## Ако DB върне constraint violation, обработва се аналогично на insert.
  mixin schemaMeta, load
  block:
    if cs.isInvalid():
      raise newException(ValidationError, "Cannot update invalid changeset")
    let conn = repo.getWriteConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildUpdateSql(cs, meta)
      # No changes to apply — just reload and return
      if sql.len == 0:
        var pkVal: string = ""
        for f in meta.fields:
          if f.primaryKey:
            try:
              pkVal = getFieldValRuntime(cs.data, f.name)
            except:
              if cs.changes.hasKey(f.name):
                pkVal = cs.changes[f.name]
            break
        if pkVal.len > 0:
          let loadSql = "SELECT * FROM \"" & meta.tableName &
                        "\" WHERE \"" & meta.primaryKeyField & "\" = $1"
          let rows = repo.adapter.query(conn, loadSql, @[pkVal])
          if rows.len > 0:
            load(rows[0], T)
          else:
            cs.data
        else:
          cs.data
      else:
        repo.adapter.exec(conn, sql, args)
        var pkVal: string = ""
        for f in meta.fields:
          if f.primaryKey:
            if cs.changes.hasKey(f.name):
              pkVal = cs.changes[f.name]
            break
        if pkVal.len == 0:
          for f in meta.fields:
            if f.primaryKey:
              try:
                pkVal = getFieldValRuntime(cs.data, f.name)
              except:
                discard
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
      repo.releaseConn(conn, repo.adapter)

template delete*[T](repo: Repo, cs: Changeset[T]): T =
  ## Изтрива запис от changeset.
  ## Ако schema-та има soft_deletes, прави soft delete (UPDATE deleted_at).
  mixin schemaMeta
  block:
    let conn = repo.getWriteConn()
    try:
      let meta = schemaMeta(T)
      if meta.softDeletes:
        let (sql, args) = buildSoftDeleteSql(cs, meta)
        repo.adapter.exec(conn, sql, args)
      else:
        let (sql, args) = buildDeleteSql(cs, meta)
        repo.adapter.exec(conn, sql, args)
      cs.data
    finally:
      repo.releaseConn(conn, repo.adapter)

template hardDelete*[T](repo: Repo, cs: Changeset[T]): T =
  ## Винаги прави истински DELETE, независимо от soft_deletes.
  mixin schemaMeta
  block:
    let conn = repo.getWriteConn()
    try:
      let meta = schemaMeta(T)
      let (sql, args) = buildDeleteSql(cs, meta)
      repo.adapter.exec(conn, sql, args)
      cs.data
    finally:
      repo.releaseConn(conn, repo.adapter)

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

proc `hardDelete!`*[T](repo: Repo, cs: Changeset[T]): T =
  result = repo.hardDelete(cs)

# --- Transaction API ---

proc transaction*(repo: Repo, body: proc()) =
  ## Изпълнява блок в транзакция.
  ## Всички repo операции вътре в body ползват една и съща връзка.
  let conn = repo.adapter.connect()
  let prevConn = threadLocalConn
  let prevStack = savepointStack
  threadLocalConn = conn
  savepointStack = @[]
  try:
    repo.adapter.beginTransaction(conn)
    body()
    repo.adapter.commitTransaction(conn)
  except RollbackError:
    # Graceful manual rollback — не re-raise-ваме
    try:
      repo.adapter.rollbackTransaction(conn)
    except:
      discard
  except:
    try:
      repo.adapter.rollbackTransaction(conn)
    except:
      discard
    raise
  finally:
    threadLocalConn = prevConn
    savepointStack = prevStack
    repo.adapter.disconnect(conn)

template savepoint*(repo: Repo, name: string, body: untyped): untyped =
  ## Изпълнява блок в PostgreSQL SAVEPOINT.
  ## Ако body хвърли изключение, rollback-ва до този savepoint.
  block:
    if threadLocalConn == nil:
      raise newException(QueryError, "savepoint requires an active transaction")
    repo.adapter.savepoint(threadLocalConn, name)
    savepointStack.add(name)
    try:
      body
      # Не release-ваме savepoint - при COMMIT се release-ват автоматично
    except:
      repo.adapter.rollbackToSavepoint(threadLocalConn, name)
      # Премахваме този savepoint и всички след него от стека
      while savepointStack.len > 0 and savepointStack[^1] != name:
        discard savepointStack.pop()
      if savepointStack.len > 0 and savepointStack[^1] == name:
        discard savepointStack.pop()
      raise

template rollbackTo*(repo: Repo, name: string): untyped =
  ## Rollback до named savepoint.
  if threadLocalConn == nil:
    raise newException(QueryError, "rollbackTo requires an active transaction")
  repo.adapter.rollbackToSavepoint(threadLocalConn, name)
  while savepointStack.len > 0 and savepointStack[^1] != name:
    discard savepointStack.pop()
  if savepointStack.len > 0 and savepointStack[^1] == name:
    discard savepointStack.pop()

proc rollback*(repo: Repo) =
  ## Graceful rollback на текущата транзакция.
  ## Хвърля RollbackError който transaction() хваща и изпълнява ROLLBACK.
  raise newException(RollbackError, "Transaction rolled back manually")

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
  var readHostVal: NimNode = nil
  var readPortVal: NimNode = nil
  var readPoolSizeVal: NimNode = nil

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
      of "read_host":
        readHostVal = child[1]
      of "read_port":
        readPortVal = child[1]
      of "read_pool_size":
        readPoolSizeVal = child[1]

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

  # Build the constructor body AST manually to avoid quote interpolation issues
  var ctorBody = newStmtList()
  ctorBody.add(newVarStmt(newIdentNode("adapter"),
    newCall(newIdentNode("newPostgresAdapter"),
      hostVal, userVal, passVal, dbVal, portVal, poolSizeVal
    )
  ))

  if readHostVal != nil:
    let rp = if readPortVal != nil: readPortVal else: portVal
    let rps = if readPoolSizeVal != nil: readPoolSizeVal else: poolSizeVal
    ctorBody.add(newVarStmt(newIdentNode("readAdapter"),
      newCall(newIdentNode("newPostgresAdapter"),
        readHostVal, userVal, passVal, dbVal, rp, rps
      )
    ))
    ctorBody.add(nnkAsgn.newTree(newIdentNode("result"),
      nnkObjConstr.newTree(typeName,
        nnkExprColonExpr.newTree(newIdentNode("adapter"), newIdentNode("adapter")),
        nnkExprColonExpr.newTree(newIdentNode("readAdapter"), newIdentNode("readAdapter"))
      )
    ))
  else:
    ctorBody.add(nnkAsgn.newTree(newIdentNode("result"),
      nnkObjConstr.newTree(typeName,
        nnkExprColonExpr.newTree(newIdentNode("adapter"), newIdentNode("adapter")),
        nnkExprColonExpr.newTree(newIdentNode("readAdapter"), newIdentNode("adapter"))
      )
    ))

  var ctorProc = newTree(nnkProcDef,
    newTree(nnkPostfix, newIdentNode("*"), procName),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams, typeName),
    newEmptyNode(),
    newEmptyNode(),
    ctorBody
  )

  result.add(ctorProc)

  result.add(quote do:
    let `instanceName`* = `procName`()
  )
