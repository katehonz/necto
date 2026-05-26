## Necto PostgreSQL Adapter
##
## Имплементация върху db_connector/db_postgres.
## Предоставя connection pooling и правилно mapping на Row типове.

import std/[locks, deques, strutils]
import db_connector/db_postgres as pg
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
  let pgQuery = pg.sql(sql)
  var dbRows: seq[DbRow] = @[]
  for row in pgConn.dbConn.fastRows(pgQuery, args):
    var dbRow: DbRow = @[]
    for i in 0..<row.len:
      dbRow.add(row[i])
    dbRows.add(dbRow)
  dbRows

method exec*(a: PostgresAdapter, conn: Connection, sql: string,
             args: seq[string] = @[]) =
  ## Изпълнява DDL/DML заявка (CREATE, INSERT, UPDATE, DELETE).
  let pgConn = PgConnection(conn)
  let pgQuery = pg.sql(sql)
  pgConn.dbConn.exec(pgQuery, args)

method execAffected*(a: PostgresAdapter, conn: Connection, sql: string,
                     args: seq[string] = @[]): int64 =
  ## Изпълнява заявка и връща брой засегнати редове (за UPDATE/DELETE).
  let pgConn = PgConnection(conn)
  let pgQuery = pg.sql(sql)
  pgConn.dbConn.execAffectedRows(pgQuery, args)

method scalar*(a: PostgresAdapter, conn: Connection, sql: string,
               args: seq[string] = @[]): string =
  ## Изпълнява заявка и връща първата колона от първия ред.
  let pgConn = PgConnection(conn)
  let pgQuery = pg.sql(sql)
  pgConn.dbConn.getValue(pgQuery, args)

method insertReturning*(a: PostgresAdapter, conn: Connection,
                        sql: string, pkName: string,
                        args: seq[string] = @[]): int64 =
  ## Изпълнява INSERT ... RETURNING pk и връща генерирания ID.
  let pgConn = PgConnection(conn)
  let pgQuery = pg.sql(sql & " RETURNING " & pkName)
  pgConn.dbConn.getValue(pgQuery, args).parseInt()

method beginTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "BEGIN", @[])

method commitTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "COMMIT", @[])

method rollbackTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "ROLLBACK", @[])
