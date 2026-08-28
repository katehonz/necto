## Necto MariaDB Adapter
##
## Имплементация върху db_connector/db_mysql.
## Предоставя connection pooling и SQL translation ($N → ?).

import std/[locks, deques, strutils, monotimes, times]
import db_connector/db_mysql as my
import ./base
import ./common

export base

type
  MariaDbConnection* = ref object of Connection
    dbConn*: my.DbConn
    isClosed*: bool

  MariaDbAdapter* = ref object of Adapter
    poolLock: Lock
    poolCond: Cond
    pool: Deque[my.DbConn]
    maxConns: int
    activeConns: int
    # Metrics
    metricsTotalRequests: int64
    metricsTotalWaitNs: int64
    metricsMaxWaitNs: int64
    metricsPeakActiveConns: int
    metricsPoolExhaustedCount: int64
    # Slow query
    slowQuery*: SlowQueryTracker
    checkoutTimeoutMs*: int  ## 0 = fail immediately when pool is full; >0 wait up to N ms

# --- Конструктор и Connection Pool ---

proc buildConnString(host: string; port: int): string =
  if port != 3306:
    host & ":" & $port
  else:
    host

proc newConnection*(a: MariaDbAdapter): my.DbConn =
  let connStr = buildConnString(a.host, a.port)
  let conn = my.open(connStr, a.user, a.password, a.database)
  discard conn.setEncoding("UTF8")
  if a.slowQuery.thresholdMs > 0:
    my.exec(conn, sql"SET SESSION max_execution_time = ?", $a.slowQuery.thresholdMs)
  conn

proc newMariaDbAdapter*(host, user, password, database: string;
                        port: int = 3306;
                        poolSize: int = 10;
                        queryTimeoutMs: int = 0;
                        slowQueryThresholdMs: int = 0;
                        checkoutTimeoutMs: int = 5000): MariaDbAdapter =
  result = MariaDbAdapter(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    poolSize: poolSize,
    dialect: pdMariaDb,
    maxConns: poolSize,
    activeConns: 0,
    metricsTotalRequests: 0,
    metricsTotalWaitNs: 0,
    metricsMaxWaitNs: 0,
    metricsPeakActiveConns: 0,
    metricsPoolExhaustedCount: 0,
    slowQuery: SlowQueryTracker(thresholdMs: slowQueryThresholdMs),
    checkoutTimeoutMs: checkoutTimeoutMs
  )
  initLock(result.poolLock)
  initCond(result.poolCond)
  result.pool = initDeque[my.DbConn]()

proc recordCheckoutWait(a: MariaDbAdapter, start: MonoTime) =
  let waitNs = (getMonoTime() - start).inNanoseconds
  a.metricsTotalWaitNs += waitNs
  if waitNs > a.metricsMaxWaitNs:
    a.metricsMaxWaitNs = waitNs

proc checkout*(a: MariaDbAdapter): my.DbConn =
  ## Не държи pool lock докато отваря TCP връзка.
  ## Ако пулът е пълен, чака на condvar до `checkoutTimeoutMs` (0 = веднага грешка).
  let start = getMonoTime()
  var createNew = false
  acquire(a.poolLock)
  inc a.metricsTotalRequests
  try:
    while true:
      if a.pool.len > 0:
        a.recordCheckoutWait(start)
        return a.pool.popFirst()
      if a.activeConns < a.maxConns:
        inc a.activeConns
        if a.activeConns > a.metricsPeakActiveConns:
          a.metricsPeakActiveConns = a.activeConns
        createNew = true
        break
      let elapsedMs = (getMonoTime() - start).inMilliseconds
      if a.checkoutTimeoutMs <= 0 or elapsedMs >= a.checkoutTimeoutMs:
        inc a.metricsPoolExhaustedCount
        a.recordCheckoutWait(start)
        raise newException(DatabaseError, "MariaDB connection pool exhausted (max: " & $a.maxConns & ")")
      waitCondTimeout(a.poolCond, a.poolLock, int(a.checkoutTimeoutMs - elapsedMs))
  finally:
    release(a.poolLock)

  if createNew:
    try:
      result = a.newConnection()
      withLock a.poolLock:
        a.recordCheckoutWait(start)
      return result
    except:
      withLock a.poolLock:
        dec a.activeConns
        signal(a.poolCond)
      raise

proc checkin*(a: MariaDbAdapter, conn: my.DbConn) =
  withLock a.poolLock:
    a.pool.addLast(conn)
    signal(a.poolCond)

method poolMetrics*(a: MariaDbAdapter): PoolMetrics =
  withLock a.poolLock:
    result = PoolMetrics(
      totalRequests: a.metricsTotalRequests,
      totalWaitMs: float64(a.metricsTotalWaitNs) / 1_000_000.0,
      maxWaitMs: float64(a.metricsMaxWaitNs) / 1_000_000.0,
      peakActiveConns: a.metricsPeakActiveConns,
      poolExhaustedCount: a.metricsPoolExhaustedCount,
      availableConns: a.pool.len
    )

method slowQueryCount*(a: MariaDbAdapter): int64 =
  a.slowQuery.count

# --- Adapter имплементация ---

method connect*(a: MariaDbAdapter): Connection =
  let db = a.checkout()
  MariaDbConnection(dbConn: db, isClosed: false)

method disconnect*(a: MariaDbAdapter, conn: Connection) =
  let myConn = MariaDbConnection(conn)
  if not myConn.isClosed:
    try:
      my.exec(myConn.dbConn, sql"ROLLBACK")
    except:
      discard
    a.checkin(myConn.dbConn)
    myConn.isClosed = true

method query*(a: MariaDbAdapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] =
  let myConn = MariaDbConnection(conn)
  let t0 = getMonoTime()
  result = runSelect(myConn.dbConn, sql, args, my.getAllRows)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method exec*(a: MariaDbAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  let myConn = MariaDbConnection(conn)
  let t0 = getMonoTime()
  runExec(myConn.dbConn, sql, args, my.exec)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method execAffected*(a: MariaDbAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  let myConn = MariaDbConnection(conn)
  let t0 = getMonoTime()
  result = runAffected(myConn.dbConn, sql, args, my.execAffectedRows)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method scalar*(a: MariaDbAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  let myConn = MariaDbConnection(conn)
  let t0 = getMonoTime()
  result = runScalar(myConn.dbConn, sql, args, my.getValue)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method insertReturning*(a: MariaDbAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  let myConn = MariaDbConnection(conn)
  let t0 = getMonoTime()
  runExec(myConn.dbConn, sql, args, my.exec)
  let idStr = runScalar(myConn.dbConn, "SELECT LAST_INSERT_ID()", @[], my.getValue)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)
  if idStr.len > 0:
    result = parseBiggestInt(idStr)
  else:
    raise newException(DatabaseError, "insertReturning: could not retrieve last insert id")

method fetchCursor*(a: MariaDbAdapter, conn: Connection, cursorName: string,
                    count: int): seq[DbRow] =
  raise newException(DatabaseError, "MariaDB adapter does not support server-side cursors. Use LIMIT/OFFSET streaming instead.")

method beginTransaction*(a: MariaDbAdapter, conn: Connection) =
  let myConn = MariaDbConnection(conn)
  my.exec(myConn.dbConn, sql"BEGIN")

method commitTransaction*(a: MariaDbAdapter, conn: Connection) =
  let myConn = MariaDbConnection(conn)
  my.exec(myConn.dbConn, sql"COMMIT")

method rollbackTransaction*(a: MariaDbAdapter, conn: Connection) =
  let myConn = MariaDbConnection(conn)
  my.exec(myConn.dbConn, sql"ROLLBACK")

method savepoint*(a: MariaDbAdapter, conn: Connection, name: string) =
  let myConn = MariaDbConnection(conn)
  var q = my.SqlQuery("SAVEPOINT " & name)
  my.exec(myConn.dbConn, q)

method rollbackToSavepoint*(a: MariaDbAdapter, conn: Connection, name: string) =
  let myConn = MariaDbConnection(conn)
  var q = my.SqlQuery("ROLLBACK TO SAVEPOINT " & name)
  my.exec(myConn.dbConn, q)
