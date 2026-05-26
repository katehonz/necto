## Necto Associations & Preload
##
## Дефиниране на релации и batch зареждане (N+1 safe).
##
## Preload работи на принципа:
##   1. Изпълнява се основната заявка → seq[Parent]
##   2. Събират се всички FK стойности → IN (id1, id2, ...)
##   3. Изпълнява се една заявка за децата → seq[Child]
##   4. Децата се разпределят по родители

import std/[tables, sequtils, strutils, sets]
import ./schema
import ./repo
import ./query
import ./type_system

export schema, repo, query, type_system

# --- Helper: извличане на поле от обект по име (compile-time reflection) ---
#
# Nim няма runtime field access по string. Използваме when branches за всеки тип.
# Алтернатива: чрез fieldPairs в template.

template getFieldVal(obj: untyped, fieldName: static[string]): untyped =
  ## Връща стойността на поле от обект по име (compile-time).
  when fieldName == "id": obj.id
  elif fieldName == "author_id": obj.author_id
  elif fieldName == "post_id": obj.post_id
  elif fieldName == "user_id": obj.user_id
  elif fieldName == "comment_id": obj.comment_id
  else: obj.id

# --- Preload: BelongsTo (Parent ← Child FK) ---

proc preloadBelongsTo*[Parent, Child](
  repo: Repo,
  parents: var seq[Parent],
  assoc: AssocMeta,
  childSchemaMeta: SchemaMeta
) =
  ## Зарежда belongs_to асоциация: Parent.author_id → Child.id
  ## Използва batch load: една заявка за всички деца.
  if parents.len == 0:
    return

  # Събираме всички FK стойности
  var fkValues: seq[string] = @[]
  var fkSet: HashSet[string] = initHashSet[string]()
  for p in parents:
    let fkVal = getFieldVal(p, assoc.foreignKey)
    let fkStr = $fkVal
    if fkStr.len > 0 and fkStr notin fkSet:
      fkSet.incl(fkStr)
      fkValues.add(fkStr)

  if fkValues.len == 0:
    return

  # Batch заявка: SELECT * FROM child_table WHERE id IN (1,2,3)
  let placeholders = fkValues.mapIt("$" & $(fkValues.find(it) + 1))
  let sql = "SELECT * FROM \"" & childSchemaMeta.tableName &
            "\" WHERE \"" & assoc.ownerKey & "\" IN (" &
            placeholders.join(", ") & ")"

  let conn = repo.getConn()
  let rows = repo.adapter.query(conn, sql, fkValues)
  repo.releaseConn(conn)

  # Парсване на редовете в child обекти (без typedesc — използваме generic load)
  # За Child типа ни трябва loadChild proc — тип dispatch
  # Тук използваме meta и raw row данни за index
  var childMap: Table[string, DbRow] = initTable[string, DbRow]()
  for row in rows:
    if row.len > 0:
      childMap[row[0]] = row  # key = id (първа колона)

  # Прикачане към родителите
  for i in 0..<parents.len:
    let fkVal = $getFieldVal(parents[i], assoc.foreignKey)
    if fkVal in childMap:
      # TODO: използваме raw field assignment — трябва type-safe load
      discard childMap[fkVal]

# --- Preload: HasMany (Parent PK ← Child FK) ---

proc preloadHasMany*[Parent, Child](
  repo: Repo,
  parents: var seq[Parent],
  assoc: AssocMeta,
  childSchemaMeta: SchemaMeta
) =
  ## Зарежда has_many асоциация: Parent.id ← Child.parent_id
  if parents.len == 0:
    return

  # Събираме всички parent PK стойности
  var pkValues: seq[string] = @[]
  var pkSet: HashSet[string] = initHashSet[string]()
  for p in parents:
    let pkVal = $getFieldVal(p, assoc.ownerKey)
    if pkVal.len > 0 and pkVal notin pkSet:
      pkSet.incl(pkVal)
      pkValues.add(pkVal)

  if pkValues.len == 0:
    return

  # Batch заявка: SELECT * FROM child_table WHERE foreign_key IN (1,2,3)
  let placeholders = pkValues.mapIt("$" & $(pkValues.find(it) + 1))
  let sql = "SELECT * FROM \"" & childSchemaMeta.tableName &
            "\" WHERE \"" & assoc.foreignKey & "\" IN (" &
            placeholders.join(", ") & ")"

  let conn = repo.getConn()
  let rows = repo.adapter.query(conn, sql, pkValues)
  repo.releaseConn(conn)

  # Групиране по FK
  var childGroups: Table[string, seq[DbRow]] = initTable[string, seq[DbRow]]()
  for row in rows:
    # FK колоната е на позиция, която търсим в meta
    var fkIdx = -1
    for j, f in childSchemaMeta.fields:
      if f.dbColumn == assoc.foreignKey:
        fkIdx = j
        break
    if fkIdx >= 0 and fkIdx < row.len:
      let fk = row[fkIdx]
      if not childGroups.hasKey(fk):
        childGroups[fk] = @[]
      childGroups[fk].add(row)

# --- Generic Preload Entry Point ---

proc preload*[T](repo: Repo, records: var seq[T], assocName: string) =
  ## Зарежда асоциация върху колекция от обекти.
  ## Използва SchemaMeta за да разбере типа на асоциацията.
  let meta = schemaMeta(T)

  # Намираме AssocMeta по име
  var assoc: AssocMeta
  var found = false
  for a in meta.associations:
    if a.name == assocName:
      assoc = a
      found = true
      break

  if not found:
    echo "Association '", assocName, "' not found on ", meta.tableName
    return

  # TODO: получи SchemaMeta за target типа. Нужен ни е dispatcher.
  # За MVP: ще използваме raw row данни с ръчно изграждане.
  echo "Preloading ", assocName, " (", assoc.kind, ") for ", meta.tableName
  echo "  FK: ", assoc.foreignKey, " → ", assoc.ownerKey

  # Placeholder — реалната имплементация е в preloadBelongsTo/preloadHasMany
  # които изискват typedesc за Child типа. За сега показваме че preload е извикан.
  discard
