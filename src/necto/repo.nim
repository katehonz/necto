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

import std/[macros, tables, options, sequtils, strutils]
import ./adapters/base
import ./errors

export base, errors

# --- Repo тип и публичен API (runtime част) ---

type
  RepoObj* = object of RootObj
    ## Runtime състояние на Repo.
    adapter*: Adapter

  Repo* = ref RepoObj

proc newRepo*(adapter: Adapter): Repo =
  Repo(adapter: adapter)

# --- Query API (placeholder до Query модула) ---

proc all*(repo: Repo, queryObj: auto): seq[auto] =
  ## Изпълнява SELECT заявка и връща seq от резултати.
  # TODO: интеграция с Query Builder + Schema Loader
  @[]

proc one*(repo: Repo, queryObj: auto): Option[auto] =
  ## Връща един резултат или none.
  # TODO
  none(typeof(auto))

proc count*(repo: Repo, queryObj: auto): int64 =
  ## Връща брой редове.
  # TODO
  0'i64

# --- Write API (placeholder до Changeset модула) ---

proc insert*(repo: Repo, changeset: auto): auto =
  ## Вмъква запис от changeset.
  # TODO
  changeset.data

proc `insert!`*[T](repo: Repo, changeset: T): T =
  ## Вмъква запис или вдига ValidationError.
  result = repo.insert(changeset)
  # TODO: проверка за валидност

proc update*(repo: Repo, changeset: auto): auto =
  ## Актуализира запис.
  changeset.data

proc `update!`*[T](repo: Repo, changeset: T): T =
  result = repo.update(changeset)

proc delete*(repo: Repo, changeset: auto): auto =
  ## Изтрива запис.
  changeset.data

proc `delete!`*[T](repo: Repo, changeset: T): T =
  result = repo.delete(changeset)

# --- Transaction API ---

proc transaction*(repo: Repo, body: proc()) =
  ## Изпълнява блок в транзакция.
  let conn = repo.adapter.connect()
  try:
    repo.adapter.beginTransaction(conn)
    body()
    repo.adapter.commitTransaction(conn)
  except RollbackError:
    repo.adapter.rollbackTransaction(conn)
    raise
  except:
    repo.adapter.rollbackTransaction(conn)
    raise
  finally:
    repo.adapter.disconnect(conn)

# --- Макро за дефиниране на Repo ---

macro necto_repo*(name: untyped, body: untyped): untyped =
  ## Дефинира нов Repo модул/тип.
  ##
  ## Пример:
  ##   necto_repo AppRepo:
  ##     adapter PostgresAdapter
  ##     host "localhost"
  ##     database "my_app"
  result = newStmtList()

  var adapterType = ident("PostgresAdapter")
  var hostVal = newLit("localhost")
  var portVal = newLit(5432)
  var userVal = newLit("postgres")
  var passVal = newLit("")
  var dbVal = newLit("postgres")
  var poolSizeVal = newLit(10)

  for child in body:
    if child.kind == nnkCall:
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
  let instanceName = ident(toLowerAscii($name) & "Instance")
  let newProcName = ident("new" & $name)

  # type Name = ref object of Repo
  var typeDef = newTree(nnkTypeDef,
    newTree(nnkPostfix, ident("*"), typeName),
    newEmptyNode(),
    newTree(nnkRefTy,
      newTree(nnkObjectTy,
        newEmptyNode(),
        newTree(nnkOfInherit, ident("Repo")),
        newTree(nnkRecList)
      )
    )
  )
  result.add(newTree(nnkTypeSection, typeDef))

  # proc newName(): Name = ...
  var procBody = newStmtList()
  var adapterConstr = newTree(nnkCall, adapterType)
  adapterConstr.add(newTree(nnkExprColonExpr, ident("host"), hostVal))
  adapterConstr.add(newTree(nnkExprColonExpr, ident("port"), portVal))
  adapterConstr.add(newTree(nnkExprColonExpr, ident("user"), userVal))
  adapterConstr.add(newTree(nnkExprColonExpr, ident("password"), passVal))
  adapterConstr.add(newTree(nnkExprColonExpr, ident("database"), dbVal))
  adapterConstr.add(newTree(nnkExprColonExpr, ident("poolSize"), poolSizeVal))

  var objConstr = newTree(nnkObjConstr,
    newTree(nnkExprColonExpr, ident("adapter"), adapterConstr)
  )
  objConstr[0] = typeName
  procBody.add(newTree(nnkAsgn, ident("result"), objConstr))

  var formalParams = newTree(nnkFormalParams, typeName)
  var newProcDef = newTree(nnkProcDef,
    newTree(nnkPostfix, ident("*"), newProcName),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    procBody
  )
  result.add(newProcDef)

  # var instance = newName()
  var varStmt = newTree(nnkVarSection,
    newTree(nnkIdentDefs,
      newTree(nnkPostfix, ident("*"), instanceName),
      newEmptyNode(),
      newTree(nnkCall, newProcName)
    )
  )
  result.add(varStmt)
