## Necto SQLite Adapter
##
## Имплементация върху db_connector/db_sqlite.
## SQLite е файл-базирана БД — connection pool-ът е тривиален (един conn на файл).
##
## Забележки:
## - SQLite placeholders са `?` (като MySQL).
## - INTEGER PRIMARY KEY е alias за ROWID → auto-increment без AUTOINCREMENT keyword.
## - Boolean се пази като INTEGER (0/1).

import std/[locks, strutils, monotimes, times]
import db_connector/db_sqlite as sq
import ./base
import ./common

export base

type
  SqliteConnection* = ref object of Connection
    dbConn*: sq.DbConn
    isClosed*: bool

  SqliteAdapter* = ref object of Adapter
    dbPath*: string
    singleConn*: sq.DbConn
    connLock*: Lock
    metricsTotalRequests: int64
    slowQuery*: SlowQueryTracker

# --- Конструктор ---

proc newSqliteAdapter*(host, user, password, database: string;
                       port: int = 0;
                       poolSize: int = 1;
                       slowQueryThresholdMs: int = 0): SqliteAdapter =
  ## Създава SQLite адаптер.
  ## `database` е пътят до файл или `:memory:` за in-memory БД.
  result = SqliteAdapter(
    dbPath: database,
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    poolSize: poolSize,
    dialect: pdSqlite,
    metricsTotalRequests: 0,
    slowQuery: SlowQueryTracker(thresholdMs: slowQueryThresholdMs)
  )
  initLock(result.connLock)
  result.singleConn = sq.open(database, "", "", "")

# --- Adapter имплементация ---

method connect*(a: SqliteAdapter): Connection =
  withLock a.connLock:
    inc a.metricsTotalRequests
  SqliteConnection(dbConn: a.singleConn, isClosed: false)

method disconnect*(a: SqliteAdapter, conn: Connection) =
  SqliteConnection(conn).isClosed = true

method query*(a: SqliteAdapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] =
  let c = SqliteConnection(conn)
  let t0 = getMonoTime()
  acquire(a.connLock)
  try:
    result = runSelect(c.dbConn, sql, args, sq.getAllRows)
  finally:
    release(a.connLock)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method exec*(a: SqliteAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  let c = SqliteConnection(conn)
  let t0 = getMonoTime()
  withLock a.connLock:
    runExec(c.dbConn, sql, args, sq.exec)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method execAffected*(a: SqliteAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  let c = SqliteConnection(conn)
  let t0 = getMonoTime()
  acquire(a.connLock)
  try:
    result = runAffected(c.dbConn, sql, args, sq.execAffectedRows)
  finally:
    release(a.connLock)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method scalar*(a: SqliteAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  let c = SqliteConnection(conn)
  let t0 = getMonoTime()
  acquire(a.connLock)
  try:
    result = runScalar(c.dbConn, sql, args, sq.getValue)
  finally:
    release(a.connLock)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method insertReturning*(a: SqliteAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  let c = SqliteConnection(conn)
  let t0 = getMonoTime()
  acquire(a.connLock)
  try:
    runExec(c.dbConn, sql, args, sq.exec)
    let idStr = runScalar(c.dbConn, "SELECT last_insert_rowid()", @[], sq.getValue)
    if idStr.len > 0:
      result = parseBiggestInt(idStr)
    else:
      raise newException(DatabaseError, "insertReturning: could not retrieve last insert id")
  finally:
    release(a.connLock)
  a.slowQuery.checkSlowQuery((getMonoTime() - t0).inNanoseconds)

method fetchCursor*(a: SqliteAdapter, conn: Connection, cursorName: string,
                    count: int): seq[DbRow] =
  raise newException(DatabaseError, "SQLite adapter does not support server-side cursors. Use LIMIT/OFFSET.")

method beginTransaction*(a: SqliteAdapter, conn: Connection) =
  withLock a.connLock:
    sq.exec(SqliteConnection(conn).dbConn, sql"BEGIN")

method commitTransaction*(a: SqliteAdapter, conn: Connection) =
  withLock a.connLock:
    sq.exec(SqliteConnection(conn).dbConn, sql"COMMIT")

method rollbackTransaction*(a: SqliteAdapter, conn: Connection) =
  withLock a.connLock:
    sq.exec(SqliteConnection(conn).dbConn, sql"ROLLBACK")

method savepoint*(a: SqliteAdapter, conn: Connection, name: string) =
  withLock a.connLock:
    var q = sq.SqlQuery("SAVEPOINT " & name)
    sq.exec(SqliteConnection(conn).dbConn, q)

method rollbackToSavepoint*(a: SqliteAdapter, conn: Connection, name: string) =
  withLock a.connLock:
    var q = sq.SqlQuery("ROLLBACK TO SAVEPOINT " & name)
    sq.exec(SqliteConnection(conn).dbConn, q)

method poolMetrics*(a: SqliteAdapter): PoolMetrics =
  withLock a.connLock:
    result = PoolMetrics(
      totalRequests: a.metricsTotalRequests,
      totalWaitMs: 0.0,
      maxWaitMs: 0.0,
      peakActiveConns: 1,
      poolExhaustedCount: 0,
      availableConns: 1
    )

method slowQueryCount*(a: SqliteAdapter): int64 =
  a.slowQuery.count
