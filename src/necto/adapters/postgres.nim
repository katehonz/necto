## Necto PostgreSQL Adapter
##
## Имплементация върху db_connector/db_postgres + libpq (low-level).
## Предоставя connection pooling и правилно mapping на Row типове.
## Всички заявки използват pqexecParams за истински $N parameter binding.

import std/[locks, deques, strutils, monotimes, times, tables]
import db_connector/db_postgres as pg
import db_connector/postgres as libpq
import ./base

export base

type
  PgConnection* = ref object of Connection
    ## Обвивка около DbConn за проследяване + prepared statement cache.
    dbConn*: pg.DbConn
    preparedCache: Table[string, string]
    stmtCounter: int

  PostgresAdapter* = ref object of Adapter
    ## PostgreSQL адаптер с вграден connection pool.
    poolLock: Lock
    pool: Deque[pg.DbConn]
    maxConns: int
    activeConns: int
    metricsTotalRequests: int64
    metricsTotalWaitNs: int64
    metricsMaxWaitNs: int64
    metricsPeakActiveConns: int
    metricsPoolExhaustedCount: int64

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
  # Винаги използваме UTF-8 encoding
  discard conn.setEncoding("UTF8")
  conn

proc newPostgresAdapter*(host, user, password, database: string;
                         port: int = 5432;
                         poolSize: int = 10): PostgresAdapter =
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
    metricsTotalRequests: 0,
    metricsTotalWaitNs: 0,
    metricsMaxWaitNs: 0,
    metricsPeakActiveConns: 0,
    metricsPoolExhaustedCount: 0
  )
  initLock(result.poolLock)
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

# --- Low-level parameter binding helpers ---

proc pgQuery(conn: PgConnection, sql: string, args: seq[string]): libpq.PPGresult =
  ## Изпълнява SQL с prepared statement cache.
  var arr = allocCStringArray(args)
  defer: deallocCStringArray(arr)

  if conn.preparedCache.hasKey(sql):
    # Използваме кеширан prepared statement
    let stmtName = conn.preparedCache[sql]
    result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)
  else:
    # Подготвяме и кешираме ново prepared statement
    inc conn.stmtCounter
    let stmtName = "necto_s" & $conn.stmtCounter
    let prepRes = libpq.pqprepare(conn.dbConn, stmtName.cstring, sql.cstring, int32(args.len), nil)
    defer: libpq.pqclear(prepRes)
    let prepStatus = libpq.pqresultStatus(prepRes)
    if prepStatus != libpq.PGRES_COMMAND_OK:
      # Fallback към директен execParams
      result = libpq.pqexecParams(conn.dbConn, sql.cstring, int32(args.len), nil, arr, nil, nil, 0)
    else:
      conn.preparedCache[sql] = stmtName
      result = libpq.pqexecPrepared(conn.dbConn, stmtName.cstring, int32(args.len), arr, nil, nil, 0)

proc pgExec(conn: PgConnection, sql: string, args: seq[string]) =
  let res = pgQuery(conn, sql, args)
  defer: libpq.pqclear(res)
  let status = libpq.pqresultStatus(res)
  if status != libpq.PGRES_COMMAND_OK and status != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))

proc pgSelect(conn: PgConnection, sql: string, args: seq[string]): seq[DbRow] =
  let res = pgQuery(conn, sql, args)
  defer: libpq.pqclear(res)
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

proc pgScalar(conn: PgConnection, sql: string, args: seq[string]): string =
  let res = pgQuery(conn, sql, args)
  defer: libpq.pqclear(res)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(conn.dbConn))
  if libpq.pqntuples(res) > 0 and libpq.pqnfields(res) > 0:
    let cval = libpq.pqgetvalue(res, 0, 0)
    if cval != nil:
      result = $cval

proc pgAffected(conn: PgConnection, sql: string, args: seq[string]): int64 =
  let res = pgQuery(conn, sql, args)
  defer: libpq.pqclear(res)
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
  ## Връща PgConnection с checkout-ната връзка + инициализиран кеш.
  let db = a.checkout()
  PgConnection(dbConn: db, preparedCache: initTable[string, string](), stmtCounter: 0)

method disconnect*(a: PostgresAdapter, conn: Connection) =
  ## Връща връзката обратно в пула.
  ## Изпълнява ROLLBACK ако сме в транзакция, след това DEALLOCATE ALL
  ## за да изчисти prepared statements от предишни PgConnection обвивки.
  let pgConn = PgConnection(conn)
  if pgConn.dbConn != nil:
    let txStatus = libpq.pqtransactionStatus(pgConn.dbConn)
    if txStatus in {libpq.PQTRANS_INTRANS, libpq.PQTRANS_INERROR}:
      try:
        let rbRes = libpq.pqexec(pgConn.dbConn, "ROLLBACK")
        libpq.pqclear(rbRes)
      except:
        discard
    try:
      let deallocRes = libpq.pqexec(pgConn.dbConn, "DEALLOCATE ALL")
      libpq.pqclear(deallocRes)
    except:
      discard
    a.checkin(pgConn.dbConn)
    pgConn.dbConn = nil

method query*(a: PostgresAdapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] =
  ## Изпълнява SELECT заявка и връща редовете.
  let pgConn = PgConnection(conn)
  pgSelect(pgConn, sql, args)

method exec*(a: PostgresAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  ## Изпълнява DDL/DML заявка (CREATE, INSERT, UPDATE, DELETE).
  let pgConn = PgConnection(conn)
  pgExec(pgConn, sql, args)

method execAffected*(a: PostgresAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  ## Изпълнява заявка и връща брой засегнати редове (за UPDATE/DELETE).
  let pgConn = PgConnection(conn)
  pgAffected(pgConn, sql, args)

method scalar*(a: PostgresAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  ## Изпълнява заявка и връща първата колона от първия ред.
  let pgConn = PgConnection(conn)
  pgScalar(pgConn, sql, args)

method insertReturning*(a: PostgresAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  ## Изпълнява INSERT ... RETURNING pk и връща генерирания ID.
  let pgConn = PgConnection(conn)
  let res = pgQuery(pgConn, sql & " RETURNING " & pkName, args)
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
