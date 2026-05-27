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

  PrepStmtMetrics* = object
    ## Метрики за prepared statement cache.
    hits*: int64
    misses*: int64
    cached*: int

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

method prepStmtMetrics*(a: Adapter): PrepStmtMetrics {.base.} =
  ## Връща метрики за prepared statement cache. Базовата имплементация връща празни метрики.
  PrepStmtMetrics()

method slowQueryCount*(a: Adapter): int64 {.base.} =
  ## Връща броя на бавните заявки. Базовата имплементация връща 0.
  0

proc toPrometheus*(m: PoolMetrics; namespace: string = "necto"): string =
  ## Експортира метриките в Prometheus текстов формат.
  ## Може да се използва директно в HTTP endpoint:
  ##   resp Http200, @[("Content-Type", "text/plain")], repo.adapter.poolMetrics().toPrometheus()
  result = ""
  result.add("# HELP " & namespace & "_pool_total_requests Total number of connection requests\n")
  result.add("# TYPE " & namespace & "_pool_total_requests counter\n")
  result.add(namespace & "_pool_total_requests " & $m.totalRequests & "\n\n")

  result.add("# HELP " & namespace & "_pool_wait_ms_total Cumulative wait time for connections (ms)\n")
  result.add("# TYPE " & namespace & "_pool_wait_ms_total counter\n")
  result.add(namespace & "_pool_wait_ms_total " & $(m.totalWaitMs * 1000.0).int64 & "\n\n")

  result.add("# HELP " & namespace & "_pool_wait_ms_max Max wait time for a connection (ms)\n")
  result.add("# TYPE " & namespace & "_pool_wait_ms_max gauge\n")
  result.add(namespace & "_pool_wait_ms_max " & $(m.maxWaitMs * 1000.0).int64 & "\n\n")

  result.add("# HELP " & namespace & "_pool_active_connections_peak Peak number of active connections\n")
  result.add("# TYPE " & namespace & "_pool_active_connections_peak gauge\n")
  result.add(namespace & "_pool_active_connections_peak " & $m.peakActiveConns & "\n\n")

  result.add("# HELP " & namespace & "_pool_exhausted_count Total times the pool was exhausted\n")
  result.add("# TYPE " & namespace & "_pool_exhausted_count counter\n")
  result.add(namespace & "_pool_exhausted_count " & $m.poolExhaustedCount & "\n\n")

  result.add("# HELP " & namespace & "_pool_available_connections Currently available connections in pool\n")
  result.add("# TYPE " & namespace & "_pool_available_connections gauge\n")
  result.add(namespace & "_pool_available_connections " & $m.availableConns & "\n")

proc toPrometheus*(m: PrepStmtMetrics; namespace: string = "necto"): string =
  ## Експортира prepared statement метриките в Prometheus текстов формат.
  result = ""
  result.add("# HELP " & namespace & "_prepstmt_hits_total Total prepared statement cache hits\n")
  result.add("# TYPE " & namespace & "_prepstmt_hits_total counter\n")
  result.add(namespace & "_prepstmt_hits_total " & $m.hits & "\n\n")

  result.add("# HELP " & namespace & "_prepstmt_misses_total Total prepared statement cache misses\n")
  result.add("# TYPE " & namespace & "_prepstmt_misses_total counter\n")
  result.add(namespace & "_prepstmt_misses_total " & $m.misses & "\n\n")

  result.add("# HELP " & namespace & "_prepstmt_cached Number of cached prepared statements\n")
  result.add("# TYPE " & namespace & "_prepstmt_cached gauge\n")
  result.add(namespace & "_prepstmt_cached " & $m.cached & "\n")

proc toPrometheus*(pool: PoolMetrics, prep: PrepStmtMetrics; namespace: string = "necto"): string =
  ## Експортира всички метрики (pool + prepared statements) в един Prometheus скрап.
  result = pool.toPrometheus(namespace)
  if result.len > 0 and result[^1] != '\n':
    result.add("\n")
  result.add(prep.toPrometheus(namespace))
