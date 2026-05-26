## Necto PostgreSQL Adapter
##
## Имплементация върху db_connector/db_postgres + libpq (low-level).
## Предоставя connection pooling и правилно mapping на Row типове.
## Всички заявки използват pqexecParams за истински $N parameter binding.

import std/[locks, deques, strutils]
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
    activeConns: 0
  )
  initLock(result.poolLock)
  result.pool = initDeque[pg.DbConn]()

proc checkout*(a: PostgresAdapter): pg.DbConn =
  ## Взема връзка от пула или създава нова.
  withLock a.poolLock:
    if a.pool.len > 0:
      return a.pool.popFirst()
    if a.activeConns < a.maxConns:
      inc a.activeConns
      return a.newConnection()
    else:
      raise newException(DbError, "PostgreSQL connection pool exhausted (max: " & $a.maxConns & ")")

proc checkin*(a: PostgresAdapter, conn: pg.DbConn) =
  ## Връща връзка обратно в пула.
  withLock a.poolLock:
    a.pool.addLast(conn)

# --- Low-level parameter binding helpers ---

proc pgQuery(db: pg.DbConn, sql: string, args: seq[string]): libpq.PPGresult =
  ## Изпълнява SQL с $N placeholders през pqexecParams.
  var arr = allocCStringArray(args)
  defer: deallocCStringArray(arr)
  result = libpq.pqexecParams(db, sql.cstring, int32(args.len), nil, arr, nil, nil, 0)

proc pgExec(db: pg.DbConn, sql: string, args: seq[string]) =
  let res = pgQuery(db, sql, args)
  defer: libpq.pqclear(res)
  let status = libpq.pqresultStatus(res)
  if status != libpq.PGRES_COMMAND_OK and status != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(db))

proc pgSelect(db: pg.DbConn, sql: string, args: seq[string]): seq[DbRow] =
  let res = pgQuery(db, sql, args)
  defer: libpq.pqclear(res)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(db))
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

proc pgScalar(db: pg.DbConn, sql: string, args: seq[string]): string =
  let res = pgQuery(db, sql, args)
  defer: libpq.pqclear(res)
  if libpq.pqresultStatus(res) != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(db))
  if libpq.pqntuples(res) > 0 and libpq.pqnfields(res) > 0:
    let cval = libpq.pqgetvalue(res, 0, 0)
    if cval != nil:
      result = $cval

proc pgAffected(db: pg.DbConn, sql: string, args: seq[string]): int64 =
  let res = pgQuery(db, sql, args)
  defer: libpq.pqclear(res)
  let status = libpq.pqresultStatus(res)
  if status != libpq.PGRES_COMMAND_OK and status != libpq.PGRES_TUPLES_OK:
    raise newException(DatabaseError, $libpq.pqErrorMessage(db))
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
  let pgConn = PgConnection(conn)
  if pgConn.dbConn != nil:
    a.checkin(pgConn.dbConn)
    pgConn.dbConn = nil

method query*(a: PostgresAdapter, conn: Connection, sql: string,
              args: seq[string] = @[]): seq[DbRow] =
  ## Изпълнява SELECT заявка и връща редовете.
  let pgConn = PgConnection(conn)
  pgSelect(pgConn.dbConn, sql, args)

method exec*(a: PostgresAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  ## Изпълнява DDL/DML заявка (CREATE, INSERT, UPDATE, DELETE).
  let pgConn = PgConnection(conn)
  pgExec(pgConn.dbConn, sql, args)

method execAffected*(a: PostgresAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  ## Изпълнява заявка и връща брой засегнати редове (за UPDATE/DELETE).
  let pgConn = PgConnection(conn)
  pgAffected(pgConn.dbConn, sql, args)

method scalar*(a: PostgresAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  ## Изпълнява заявка и връща първата колона от първия ред.
  let pgConn = PgConnection(conn)
  pgScalar(pgConn.dbConn, sql, args)

method insertReturning*(a: PostgresAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  ## Изпълнява INSERT ... RETURNING pk и връща генерирания ID.
  let pgConn = PgConnection(conn)
  let res = pgQuery(pgConn.dbConn, sql & " RETURNING " & pkName, args)
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
