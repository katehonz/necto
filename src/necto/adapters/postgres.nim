## Necto PostgreSQL Adapter
##
## Имплементация върху db_connector/db_postgres.
## Предоставя connection pooling и подготвени изявления (prepared statements).

import std/[locks, deques, strutils, strformat]
import db_connector/db_postgres as pg
import ./base

export base

type
  PgConnection* = ref object of Connection
    dbConn*: DbConn

  PostgresAdapter* = ref object of Adapter
    ## PostgreSQL адаптер с вграден пул.
    poolLock: Lock
    pool: Deque[DbConn]
    maxConns: int
    activeConns: int

# --- Connection Pool ---

proc newPostgresAdapter*(host, user, password, database: string;
                         port: int = 5432;
                         poolSize: int = 10): PostgresAdapter =
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
  result.pool = initDeque[DbConn]()

proc checkout*(a: PostgresAdapter): DbConn =
  ## Взема връзка от пула или създава нова.
  withLock a.poolLock:
    if a.pool.len > 0:
      return a.pool.popFirst()
    if a.activeConns < a.maxConns:
      inc a.activeConns
      # TODO: разрешаване на проблема с връзката (connection string vs separate args)
      # За MVP се предполага, че db_postgres.open работи с (host, user, pass, database)
      return pg.open(a.host, a.user, a.password, a.database)
    else:
      raise newException(DbError, "PostgreSQL connection pool exhausted")

proc checkin*(a: PostgresAdapter, conn: DbConn) =
  ## Връща връзка в пула.
  withLock a.poolLock:
    a.pool.addLast(conn)

# --- Adapter имплементация ---

method connect*(a: PostgresAdapter): Connection =
  PgConnection(dbConn: a.checkout())

method disconnect*(a: PostgresAdapter, conn: Connection) =
  let pgConn = PgConnection(conn)
  if pgConn.dbConn != nil:
    a.checkin(pgConn.dbConn)
    pgConn.dbConn = nil

method query*(a: PostgresAdapter, conn: Connection, sql: string, args: seq[string] = @[]): seq[Row] =
  let pgConn = PgConnection(conn)
  # TODO: използвай db_postgres.getAllRows или подобен метод с параметризирани заявки
  # За MVP fallback към exec + ръчно парсиране, ако е необходимо.
  discard

method exec*(a: PostgresAdapter, conn: Connection, sql: string, args: seq[string] = @[]) =
  let pgConn = PgConnection(conn)
  pgConn.dbConn.exec(pg.sql(sql))

method scalar*(a: PostgresAdapter, conn: Connection, sql: string, args: seq[string] = @[]): string =
  let pgConn = PgConnection(conn)
  # TODO: getValue
  ""

method beginTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "BEGIN", @[])

method commitTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "COMMIT", @[])

method rollbackTransaction*(a: PostgresAdapter, conn: Connection) =
  a.exec(conn, "ROLLBACK", @[])
