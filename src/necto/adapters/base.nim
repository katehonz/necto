## Necto Adapter Base
##
## Интерфейс за database adapters. Всеки адаптер трябва да имплементира
## основните CRUD операции, транзакции и connection pooling.

# No stdlib imports needed for base adapter interface

type
  DbRow* = seq[string]
    ## Ред от базата данни като seq от низове.

  DatabaseError* = object of CatchableError
    ## Грешка при работа с базата данни.

  PoolMetrics* = object
    ## Метрики за connection pool-а.
    totalRequests*: int64
    totalWaitMs*: float64
    maxWaitMs*: float64
    peakActiveConns*: int
    poolExhaustedCount*: int64
    availableConns*: int

  Adapter* = ref object of RootObj
    ## Абстрактен базов адаптер.
    host*: string
    port*: int
    user*: string
    password*: string
    database*: string
    poolSize*: int

  Connection* = ref object of RootObj
    ## Абстрактна връзка към базата данни. Всеки адаптер я subclass-ва.

# --- Абстрактни методи ---

method connect*(a: Adapter): Connection {.base.} =
  ## Взема връзка от пула. Връща Connection (или subclass).
  raise newException(DatabaseError, "connect not implemented")

method disconnect*(a: Adapter, conn: Connection) {.base.} =
  ## Връща връзка обратно в пула.
  raise newException(DatabaseError, "disconnect not implemented")

method query*(a: Adapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] {.base.} =
  ## Изпълнява SELECT заявка и връща seq от DbRow.
  raise newException(DatabaseError, "query not implemented")

method exec*(a: Adapter, conn: Connection, sql: string,
             args: seq[string] = @[]) {.base.} =
  ## Изпълнява заявка без резултат (DDL, INSERT без RETURNING).
  raise newException(DatabaseError, "exec not implemented")

method execAffected*(a: Adapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 {.base.} =
  ## Изпълнява заявка и връща брой засегнати редове.
  raise newException(DatabaseError, "execAffected not implemented")

method scalar*(a: Adapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string {.base.} =
  ## Връща единична стойност (първа колона, първи ред).
  raise newException(DatabaseError, "scalar not implemented")

method insertReturning*(a: Adapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 {.base.} =
  ## Изпълнява INSERT ... RETURNING pkName и връща генерирания ID.
  raise newException(DatabaseError, "insertReturning not implemented")

method fetchCursor*(a: Adapter, conn: Connection, cursorName: string,
                    count: int): seq[DbRow] {.base.} =
  ## Fetch-ва до `count` реда от курсор. Връща празен seq ако курсорът е изчерпан.
  raise newException(DatabaseError, "fetchCursor not implemented")

method beginTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(DatabaseError, "beginTransaction not implemented")

method commitTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(DatabaseError, "commitTransaction not implemented")

method rollbackTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(DatabaseError, "rollbackTransaction not implemented")

method savepoint*(a: Adapter, conn: Connection, name: string) {.base.} =
  raise newException(DatabaseError, "savepoint not implemented")

method rollbackToSavepoint*(a: Adapter, conn: Connection, name: string) {.base.} =
  raise newException(DatabaseError, "rollbackToSavepoint not implemented")

method poolMetrics*(a: Adapter): PoolMetrics {.base.} =
  ## Връща метрики за connection pool-а. Базовата имплементация връща празни метрики.
  PoolMetrics()
