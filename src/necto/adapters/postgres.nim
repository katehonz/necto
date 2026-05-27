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
    preparedStmts*: Table[string, string]  ## sql → stmtName (per-connection cache)

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
    # Prepared statement cache metrics
    metricsPrepStmtHits: int64
    metricsPrepStmtMisses: int64
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
    metricsPrepStmtHits: 0,
    metricsPrepStmtMisses: 0,
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
      try:
        return a.newConnection()
      except:
        withLock a.poolLock:
          dec a.activeConns
        raise
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

method prepStmtMetrics*(a: PostgresAdapter): PrepStmtMetrics =
  ## Връща prepared statement метрики: (hits, misses, брой кеширани SQL-а).
  withLock a.prepLock:
    result = PrepStmtMetrics(hits: a.metricsPrepStmtHits, misses: a.metricsPrepStmtMisses,
                              cached: a.preparedCache.len)

# --- Low-level prepared statement + parameter binding ---

proc pgQuery(a: PostgresAdapter, conn: PgConnection, sql: string, args: seq[string]): libpq.PPGresult =
  ## Изпълнява SQL с per-connection prepared statement cache.
  var arr = allocCStringArray(args)
  defer: deallocCStringArray(arr)

  var stmtName: string
  var needPrepare = false

  # Check per-connection cache first
  if conn.preparedStmts.hasKey(sql):
    # Already prepared on this connection
    stmtName = conn.preparedStmts[sql]
    result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
    let status = libpq.pqresultStatus(result)
    if status != libpq.PGRES_FATAL_ERROR:
      inc a.metricsPrepStmtHits
      return
    # Prepared statement was lost (e.g. connection reset) — re-prepare
    libpq.pqclear(result)
    conn.preparedStmts.del(sql)
    needPrepare = true
  else:
    needPrepare = true

  if needPrepare:
    inc a.metricsPrepStmtMisses
    # Generate unique stmt name per attempt — avoids conflicts
    # when the same PG connection is reused across different PgConnection wrappers.
    inc a.stmtCounter
    stmtName = "necto_p" & $a.stmtCounter

    let prepRes = libpq.pqprepare(conn.dbConn, stmtName.cstring, sql.cstring, int32(args.len), nil)
    let prepStatus = libpq.pqresultStatus(prepRes)
    libpq.pqclear(prepRes)
    if prepStatus == libpq.PGRES_COMMAND_OK:
      conn.preparedStmts[sql] = stmtName
      result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
    else:
      # Fallback to direct execParams (also handles "already exists" errors safely)
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
  PgConnection(dbConn: db, preparedStmts: initTable[string, string]())

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

method fetchCursor*(a: PostgresAdapter, conn: Connection, cursorName: string,
                    count: int): seq[DbRow] =
  ## Fetch-ва до `count` реда от PostgreSQL курсор.
  let pgConn = PgConnection(conn)
  let sql = "FETCH FORWARD " & $count & " FROM \"" & cursorName & "\""
  pgSelect(a, pgConn, sql, @[])

method beginTransaction*(a: PostgresAdapter, conn: Connection) =
  ## Използваме pqexec директно за транзакционни команди,
  ## за да избегнем проблеми с prepared statements при abort-нати транзакции.
  let pgConn = PgConnection(conn)
  let res = libpq.pqexec(pgConn.dbConn, "BEGIN")
  let status = libpq.pqresultStatus(res)
  libpq.pqclear(res)
  if status != libpq.PGRES_COMMAND_OK:
    raise newException(DatabaseError, "BEGIN failed: " & $libpq.pqErrorMessage(pgConn.dbConn))

method commitTransaction*(a: PostgresAdapter, conn: Connection) =
  let pgConn = PgConnection(conn)
  let res = libpq.pqexec(pgConn.dbConn, "COMMIT")
  let status = libpq.pqresultStatus(res)
  libpq.pqclear(res)
  if status != libpq.PGRES_COMMAND_OK:
    raise newException(DatabaseError, "COMMIT failed: " & $libpq.pqErrorMessage(pgConn.dbConn))

method rollbackTransaction*(a: PostgresAdapter, conn: Connection) =
  ## Използваме pqexec директно, защото при abort-ната транзакция
  ## prepared statements (чрез pgExec) не работят.
  let pgConn = PgConnection(conn)
  let res = libpq.pqexec(pgConn.dbConn, "ROLLBACK")
  libpq.pqclear(res)

method savepoint*(a: PostgresAdapter, conn: Connection, name: string) =
  let pgConn = PgConnection(conn)
  let res = libpq.pqexec(pgConn.dbConn, ("SAVEPOINT " & name).cstring)
  libpq.pqclear(res)

method rollbackToSavepoint*(a: PostgresAdapter, conn: Connection, name: string) =
  let pgConn = PgConnection(conn)
  let res = libpq.pqexec(pgConn.dbConn, ("ROLLBACK TO SAVEPOINT " & name).cstring)
  libpq.pqclear(res)
