## Necto Associations & Preload
##
## Batch зареждане на асоциации (N+1 safe).
##
## Preload работи на принципа:
##   1. Събират се всички FK/PK стойности от родителите
##   2. Изпълнява се една batch заявка: SELECT * FROM children WHERE fk IN (...)
##   3. Резултатът се връща като Table за ръчно свързване

import std/[tables, strutils, sets]
import ./schema
import ./repo
import ./query
import ./type_system
import ./errors

export schema, repo, query, type_system, errors, sets

# --- Helpers ---

proc buildInPlaceholders(n: int): seq[string] =
  for i in 1..n:
    result.add("$" & $i)

# --- Preload: BelongsTo (Parent FK → Child PK) ---

template preloadBelongsTo*[Parent, Child](repo: Repo, parents: seq[Parent]): Table[int64, Child] =
  ## Зарежда belongs_to асоциация: Parent.author_id → Child.id
  ## Връща Table[child_id, Child] за ръчно свързване.
  mixin schemaMeta, load, getFieldValRuntime
  var childMap: Table[int64, Child] = initTable[int64, Child]()

  if parents.len == 0:
    childMap
  else:
    let parentMeta = schemaMeta(Parent)
    let childMeta = schemaMeta(Child)

    var assoc: AssocMeta
    var found = false
    for a in parentMeta.associations:
      if a.kind == akBelongsTo and a.targetSchema == $Child:
        assoc = a
        found = true
        break

    if not found:
      raise newException(QueryError, "No belongs_to association to " & $Child & " found on " & $Parent)

    # Събираме всички FK стойности
    var fkValues: seq[string] = @[]
    var fkSet: HashSet[string] = initHashSet[string]()
    for p in parents:
      let fkVal = getFieldValRuntime(p, assoc.foreignKey)
      if fkVal.len > 0 and fkVal notin fkSet:
        fkSet.incl(fkVal)
        fkValues.add(fkVal)

    if fkValues.len > 0:
      let placeholders = buildInPlaceholders(fkValues.len)
      let sql = "SELECT * FROM \"" & childMeta.tableName &
                "\" WHERE \"" & assoc.ownerKey & "\" IN (" & placeholders.join(", ") & ")"

      let conn = repo.getConn()
      let rows = repo.adapter.query(conn, sql, fkValues)
      repo.releaseConn(conn)

      for row in rows:
        let child = load(row, Child)
        let pkVal = parseBiggestInt(getFieldValRuntime(child, assoc.ownerKey))
        childMap[pkVal] = child

    childMap

# --- Preload: HasMany (Parent PK ← Child FK) ---

template preloadHasMany*[Parent, Child](repo: Repo, parents: seq[Parent]): Table[int64, seq[Child]] =
  ## Зарежда has_many асоциация: Parent.id ← Child.parent_id
  ## Връща Table[parent_id, seq[Child]] за ръчно свързване.
  mixin schemaMeta, load, getFieldValRuntime
  var childGroups: Table[int64, seq[Child]] = initTable[int64, seq[Child]]()

  if parents.len == 0:
    childGroups
  else:
    let parentMeta = schemaMeta(Parent)
    let childMeta = schemaMeta(Child)

    # Търсим belongs_to в childMeta за правилен foreignKey
    var fkField = ""
    for a in childMeta.associations:
      if a.kind == akBelongsTo and a.targetSchema == $Parent:
        fkField = a.foreignKey
        break

    var assoc: AssocMeta
    var found = false
    for a in parentMeta.associations:
      if a.kind == akHasMany and a.targetSchema == $Child:
        assoc = a
        found = true
        break

    if fkField.len == 0:
      fkField = assoc.foreignKey  # fallback

    if not found and fkField.len == 0:
      raise newException(QueryError, "No has_many association to " & $Child & " found on " & $Parent)

    # Събираме всички parent PK стойности
    var pkValues: seq[string] = @[]
    var pkSet: HashSet[string] = initHashSet[string]()
    for p in parents:
      let pkVal = getFieldValRuntime(p, assoc.ownerKey)
      if pkVal.len > 0 and pkVal notin pkSet:
        pkSet.incl(pkVal)
        pkValues.add(pkVal)

    if pkValues.len > 0:
      let placeholders = buildInPlaceholders(pkValues.len)
      let sql = "SELECT * FROM \"" & childMeta.tableName &
                "\" WHERE \"" & fkField & "\" IN (" & placeholders.join(", ") & ")"

      let conn = repo.getConn()
      let rows = repo.adapter.query(conn, sql, pkValues)
      repo.releaseConn(conn)

      for row in rows:
        let child = load(row, Child)
        let fkVal = parseBiggestInt(getFieldValRuntime(child, fkField))
        if not childGroups.hasKey(fkVal):
          childGroups[fkVal] = @[]
        childGroups[fkVal].add(child)

    childGroups

# --- Preload: HasOne (Parent PK ← Child FK) ---

template preloadHasOne*[Parent, Child](repo: Repo, parents: seq[Parent]): Table[int64, Child] =
  ## Зарежда has_one асоциация: Parent.id ← Child.parent_id
  ## Връща Table[parent_id, Child] за ръчно свързване.
  mixin schemaMeta, load, getFieldValRuntime
  var childMap: Table[int64, Child] = initTable[int64, Child]()

  if parents.len == 0:
    childMap
  else:
    let parentMeta = schemaMeta(Parent)
    let childMeta = schemaMeta(Child)

    # Търсим belongs_to в childMeta за правилен foreignKey
    var fkField = ""
    for a in childMeta.associations:
      if a.kind == akBelongsTo and a.targetSchema == $Parent:
        fkField = a.foreignKey
        break

    var assoc: AssocMeta
    var found = false
    for a in parentMeta.associations:
      if a.kind == akHasOne and a.targetSchema == $Child:
        assoc = a
        found = true
        break

    if fkField.len == 0:
      fkField = assoc.foreignKey  # fallback

    if not found and fkField.len == 0:
      raise newException(QueryError, "No has_one association to " & $Child & " found on " & $Parent)

    # Събираме всички parent PK стойности
    var pkValues: seq[string] = @[]
    var pkSet: HashSet[string] = initHashSet[string]()
    for p in parents:
      let pkVal = getFieldValRuntime(p, assoc.ownerKey)
      if pkVal.len > 0 and pkVal notin pkSet:
        pkSet.incl(pkVal)
        pkValues.add(pkVal)

    if pkValues.len > 0:
      let placeholders = buildInPlaceholders(pkValues.len)
      let sql = "SELECT * FROM \"" & childMeta.tableName &
                "\" WHERE \"" & fkField & "\" IN (" & placeholders.join(", ") & ")"

      let conn = repo.getConn()
      let rows = repo.adapter.query(conn, sql, pkValues)
      repo.releaseConn(conn)

      for row in rows:
        let child = load(row, Child)
        let fkVal = parseBiggestInt(getFieldValRuntime(child, fkField))
        childMap[fkVal] = child

    childMap
