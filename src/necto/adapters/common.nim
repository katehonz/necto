## Necto Adapter Common Helpers
##
## Споделени utilities между db_connector-базирани адаптери
## (MariaDB, SQLite и бъдещи). PostgreSQL адаптерът използва low-level libpq
## и не се нуждае от тези helpers.

import std/[monotimes, times]
import db_connector/db_common

# --- Placeholder translation ---

proc translatePlaceholders*(sql: string): string =
  ## Превежда PostgreSQL `$N` placeholders към `?` placeholders.
  ## Използва се от MySQL/MariaDB и SQLite адаптери.
  result = ""
  var i = 0
  while i < sql.len:
    if sql[i] == '$' and i + 1 < sql.len and sql[i + 1] in {'0'..'9'}:
      result.add('?')
      inc i
      while i < sql.len and sql[i] in {'0'..'9'}:
        inc i
    else:
      result.add(sql[i])
      inc i

# --- Slow query tracking ---

type
  SlowQueryTracker* = object
    thresholdMs*: int
    count*: int64

proc checkSlowQuery*(t: var SlowQueryTracker, elapsedNs: int64) =
  if t.thresholdMs > 0:
    let elapsedMs = float64(elapsedNs) / 1_000_000.0
    if elapsedMs > float64(t.thresholdMs):
      inc t.count

# --- Generic query helpers for db_connector-based adapters ---

import ./base

proc runSelect*[Db](db: Db, sqlStr: string, args: seq[string],
                    getAllRowsProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]): seq[seq[string]] {.nimcall.}): seq[DbRow] =
  let translated = translatePlaceholders(sqlStr)
  getAllRowsProc(db, SqlQuery(translated), args)

proc runExec*[Db](db: Db, sqlStr: string, args: seq[string],
                  execProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]) {.nimcall.}) =
  let translated = translatePlaceholders(sqlStr)
  execProc(db, SqlQuery(translated), args)

proc runScalar*[Db](db: Db, sqlStr: string, args: seq[string],
                   getValueProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]): string {.nimcall.}): string =
  let translated = translatePlaceholders(sqlStr)
  getValueProc(db, SqlQuery(translated), args)

proc runAffected*[Db](db: Db, sqlStr: string, args: seq[string],
                     execAffectedProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]): int64 {.nimcall.}): int64 =
  let translated = translatePlaceholders(sqlStr)
  execAffectedProc(db, SqlQuery(translated), args)
