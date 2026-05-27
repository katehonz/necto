## Necto PostgreSQL Adapter
##
## Имплементация върху db_connector/db_postgres + libpq (low-level).
## Предоставя connection pooling, prepared statement cache (per-adapter),
## query timeout, slow query logging и connection pool metrics.
## Всички заявки използват pqexecParams/pqexecPrepared за истински $N parameter binding.

import std/[locks, deques, strutils, monotimes, times, tables]
import db_connector/db_postgres as pg
import db_connector/postgres as libpq
import ./base

export base

type
  PgConnection* = ref object of Connection
    ## Обвивка около DbConn за проследяване.
    dbConn*: pg.DbConn

  PostgresAdapter* = ref object of Adapter
    ## PostgreSQL адаптер с вграден connection pool.
    poolLock: Lock
    pool: Deque[pg.DbConn]
    maxConns: int
    activeConns: int
    # Prepared statement cache (per-adapter, shared across connections)
    prepLock: Lock
    preparedCache: Table[string, string]  # sql → stmtName
    stmtCounter: int
    # Metrics
    metricsTotalRequests: int64
    metricsTotalWaitNs: int64
    metricsMaxWaitNs: int64
    metricsPeakActiveConns: int
    metricsPoolExhaustedCount: int64
    # Query timeout
    queryTimeoutMs*: int  # 0 = disabled
    slowQueryThresholdMs*: int  # 0 = disabled
    metricsSlowQueryCount: int64

# --- Конструктор и Connection Pool ---

proc buildConnString(host: string; port: int): string =
  ## Изгражда connection string за `db_postgres.open()`.
  if port != 5432:
    host & ":" & $port
  else:
    host

proc newConnection*(a: PostgresAdapter): pg.DbConn =
  ## Създава нова връзка с PostgreSQL.
  let connStr = buildConnString(a.host, a.port)
  let conn = pg.open(connStr, a.user, a.password, a.database)
  discard conn.setEncoding("UTF8")
  # Set statement_timeout if configured
  if a.queryTimeoutMs > 0:
    let timeoutSql = "SET statement_timeout = '" & $a.queryTimeoutMs & "ms'"
    let res = libpq.pqexec(conn, timeoutSql.cstring)
    libpq.pqclear(res)
  conn

proc newPostgresAdapter*(host, user, password, database: string;
                         port: int = 5432;
                         poolSize: int = 10;
                         queryTimeoutMs: int = 0;
                         slowQueryThresholdMs: int = 0): PostgresAdapter =
  ## Създава PostgreSQL адаптер с connection pool.
  result = PostgresAdapter(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    poolSize: poolSize,
    maxConns: poolSize,
    activeConns: 0,
    stmtCounter: 0,
    preparedCache: initTable[string, string](),
    metricsTotalRequests: 0,
    metricsTotalWaitNs: 0,
    metricsMaxWaitNs: 0,
    metricsPeakActiveConns: 0,
    metricsPoolExhaustedCount: 0,
    queryTimeoutMs: queryTimeoutMs,
    slowQueryThresholdMs: slowQueryThresholdMs,
    metricsSlowQueryCount: 0
  )
  initLock(result.poolLock)
  initLock(result.prepLock)
  result.pool = initDeque[pg.DbConn]()

proc checkout*(a: PostgresAdapter): pg.DbConn =
  ## Взема връзка от пула или създава нова.
  let start = getMonoTime()
  withLock a.poolLock:
    let waitNs = (getMonoTime() - start).inNanoseconds
    inc a.metricsTotalRequests
    a.metricsTotalWaitNs += waitNs
    if waitNs > a.metricsMaxWaitNs:
      a.metricsMaxWaitNs = waitNs

    if a.pool.len > 0:
      return a.pool.popFirst()
    if a.activeConns < a.maxConns:
      inc a.activeConns
      if a.activeConns > a.metricsPeakActiveConns:
        a.metricsPeakActiveConns = a.activeConns
      return a.newConnection()
    else:
      inc a.metricsPoolExhaustedCount
      raise newException(DbError, "PostgreSQL connection pool exhausted (max: " & $a.maxConns & ")")

proc checkin*(a: PostgresAdapter, conn: pg.DbConn) =
  ## Връща връзка обратно в пула.
  withLock a.poolLock:
    a.pool.addLast(conn)

method poolMetrics*(a: PostgresAdapter): PoolMetrics =
  ## Връща текущите метрики за pool-а.
  withLock a.poolLock:
    result = PoolMetrics(
      totalRequests: a.metricsTotalRequests,
      totalWaitMs: float64(a.metricsTotalWaitNs) / 1_000_000.0,
      maxWaitMs: float64(a.metricsMaxWaitNs) / 1_000_000.0,
      peakActiveConns: a.metricsPeakActiveConns,
      poolExhaustedCount: a.metricsPoolExhaustedCount,
      availableConns: a.pool.len
    )

# --- Query timeout и slow query helpers ---

proc checkSlowQuery(a: PostgresAdapter, elapsedNs: int64) =
  if a.slowQueryThresholdMs > 0:
    let elapsedMs = float64(elapsedNs) / 1_000_000.0
    if elapsedMs > float64(a.slowQueryThresholdMs):
      inc a.metricsSlowQueryCount

method slowQueryCount*(a: PostgresAdapter): int64 =
  a.metricsSlowQueryCount

# --- Low-level prepared statement + parameter binding ---

proc pgQuery(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]): libpq.PPGresult =
  ## Изпълнява SQL с adapter-level prepared statement cache.
  var arr = allocCStringArray(args)
  defer: deallocCStringArray(arr)

  var stmtName: string
  var cached = false
  withLock a.prepLock:
    if a.preparedCache.hasKey(sql):
      stmtName = a.preparedCache[sql]
      cached = true

  if cached:
    # Try existing prepared statement on this connection
    result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
    let status = libpq.pqresultStatus(result)
    if status == libpq.PGRES_FATAL_ERROR:
      # Statement doesn't exist on this connection — prepare it
      libpq.pqclear(result)
      let prepRes = libpq.pqprepare(conn.dbConn, stmtName.cstring, sql.cstring, int32(args.len), nil)
      let prepStatus = libpq.pqresultStatus(prepRes)
      libpq.pqclear(prepRes)
      if prepStatus == libpq.PGRES_COMMAND_OK:
        result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
      else:
        # Fallback to direct execParams
        result = libpq.pqexecParams(conn.dbConn, sql.cstring, int32(args.len), nil, arr, nil, nil, 0)
  else:
    # First time seeing this SQL — prepare and cache
    inc a.stmtCounter
    stmtName = "necto_p" & $a.stmtCounter
    let prepRes = libpq.pqprepare(conn.dbConn, stmtName.cstring, sql.cstring, int32(args.len), nil)
    let prepStatus = libpq.pqresultStatus(prepRes)
    libpq.pqclear(prepRes)
    if prepStatus == libpq.PGRES_COMMAND_OK:
      withLock a.prepLock:
        a.preparedCache[sql] = stmtName
      result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
    else:
      # Fallback to direct execParams
      result = libpq.pqexecParams(conn.dbConn, sql.cstring, int32(args.len), nil, arr, nil, nil, 0)

proc pgExec(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]) =
  let t0 = getMonoTime()
  let res = pgQuery(a, conn, sql, args)
  defer: libpq.pqclear(res)
  a.checkSlowQuery((getMonoTime() - t0).inNanoseconds)
  let status = libpq.pqresultStatus(res)
  if status != libpq.PGRES_COMMAND_OK and status != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))

proc pgSelect(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]): seq[DbRow] =
  let t0 = getMonoTime()
  let res = pgQuery(a, conn, sql, args)
  defer: libpq.pqclear(res)
  a.checkSlowQuery((getMonoTime() - t0).inNanoseconds)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))
  let nrows = libpq.pqntuples(res)
  let ncols = libpq.pqnfields(res)
  for i in 0 ..< nrows:
    var row: DbRow = @[]
    for j in 0 ..< ncols:
      let cval = libpq.pqgetvalue(res, i, j)
      if cval == nil:
        row.add("")
      else:
        row.add($cval)
    result.add(row)

proc pgScalar(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]): string =
  let t0 = getMonoTime()
  let res = pgQuery(a, conn, sql, args)
  defer: libpq.pqclear(res)
  a.checkSlowQuery((getMonoTime() - t0).inNanoseconds)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))
  if libpq.pqntuples(res) > 0 and libpq.pqnfields(res) > 0:
    let cval = libpq.pqgetvalue(res, 0, 0)
    if cval != nil:
      result = $cval

proc pgAffected(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]): int64 =
  let t0 = getMonoTime()
  let res = pgQuery(a, conn, sql, args)
  defer: libpq.pqclear(res)
  a.checkSlowQuery((getMonoTime() - t0).inNanoseconds)
  let status = libpq.pqresultStatus(res)
  if status != libpq.PGRES_COMMAND_OK and status != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))
  let ct = libpq.pqcmdTuples(res)
  if ct != nil:
    result = parseBiggestInt($ct)
  else:
    result = 0

# --- Adapter имплементация ---

method connect*(a: PostgresAdapter): Connection =
  ## Връща PgConnection с checkout-ната връзка.
  let db = a.checkout()
  PgConnection(dbConn: db)

method disconnect*(a: PostgresAdapter, conn: Connection) =
  ## Връща връзката обратно в пула.
  ## Изпълнява ROLLBACK ако сме в транзакция.
  ## НЕ деалокира prepared statements — те остават за reuse при следващ checkout.
  let pgConn = PgConnection(conn)
  if pgConn.dbConn != nil:
    let txStatus = libpq.pqtransactionStatus(pgConn.dbConn)
    if txStatus in {libpq.PQTRANS_INTRANS, libpq.PQTRANS_INERROR}:
      try:
        let rbRes = libpq.pqexec(pgConn.dbConn, "ROLLBACK")
        libpq.pqclear(rbRes)
      except:
        discard
    a.checkin(pgConn.dbConn)
    pgConn.dbConn = nil

method query*(a: PostgresAdapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] =
  let pgConn = PgConnection(conn)
  pgSelect(a, pgConn, sql, args)

method exec*(a: PostgresAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  let pgConn = PgConnection(conn)
  pgExec(a, pgConn, sql, args)

method execAffected*(a: PostgresAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  let pgConn = PgConnection(conn)
  pgAffected(a, pgConn, sql, args)

method scalar*(a: PostgresAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  let pgConn = PgConnection(conn)
  pgScalar(a, pgConn, sql, args)

method insertReturning*(a: PostgresAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  let pgConn = PgConnection(conn)
  let res = pgQuery(a, pgConn, sql & " RETURNING " & pkName, args)
  defer: libpq.pqclear(res)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(pgConn.dbConn))
  if libpq.pqntuples(res) > 0 and libpq.pqnfields(res) > 0:
    let cval = libpq.pqgetvalue(res, 0, 0)
    if cval != nil:
      result = parseBiggestInt($cval)
    else:
      raise newException(DatabaseError, "insertReturning: nil value returned")
  else:
    raise newException(DatabaseError, "insertReturning: no rows returned")

method beginTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "BEGIN", @[])

method commitTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "COMMIT", @[])

method rollbackTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "ROLLBACK", @[])
