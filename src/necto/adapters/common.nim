## Necto Adapter Common Helpers
##
## Споделени utilities между db_connector-базирани адаптери
## (MariaDB, SQLite и бъдещи). PostgreSQL адаптерът използва low-level libpq
## за parameter binding, но ползва Cond wait helper-а.

import std/locks
import db_connector/db_common
import ../type_system

when defined(posix):
  import posix except Time
else:
  import std/os

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

proc bindWithNulls*(sql: string, args: seq[string]): (string, seq[string]) =
  ## Замества placeholders, чиито аргументи са SQL NULL, с литерал `NULL`.
  let translated = translatePlaceholders(sql)
  var outSql = newStringOfCap(translated.len)
  var outArgs: seq[string] = @[]
  var argIdx = 0
  var i = 0
  while i < translated.len:
    if translated[i] == '?' and argIdx < args.len:
      if isDbNull(args[argIdx]):
        outSql.add("NULL")
      else:
        outSql.add('?')
        outArgs.add(args[argIdx])
      inc argIdx
      inc i
    else:
      outSql.add(translated[i])
      inc i
  (outSql, outArgs)

proc waitCondTimeout*(cond: var Cond, lock: var Lock, remainingMs: int) =
  ## Чака на condition variable с timeout. Caller държи `lock`.
  if remainingMs <= 0:
    return
  when defined(posix):
    var ts: Timespec
    discard clock_gettime(CLOCK_REALTIME, ts)
    let addSec = remainingMs div 1000
    let addNsec = (remainingMs mod 1000) * 1_000_000 + ts.tv_nsec.int
    ts.tv_sec = posix.Time(int64(ts.tv_sec) + addSec + addNsec div 1_000_000_000)
    ts.tv_nsec = addNsec mod 1_000_000_000
    proc pthread_cond_timedwait(cond, mutex, abstime: pointer): cint {.
      importc: "pthread_cond_timedwait", header: "<pthread.h>".}
    discard pthread_cond_timedwait(addr cond, addr lock, addr ts)
  else:
    release(lock)
    sleep(min(10, remainingMs))
    acquire(lock)

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
  let (sql, bound) = bindWithNulls(sqlStr, args)
  getAllRowsProc(db, SqlQuery(sql), bound)

proc runExec*[Db](db: Db, sqlStr: string, args: seq[string],
                  execProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]) {.nimcall.}) =
  let (sql, bound) = bindWithNulls(sqlStr, args)
  execProc(db, SqlQuery(sql), bound)

proc runScalar*[Db](db: Db, sqlStr: string, args: seq[string],
                   getValueProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]): string {.nimcall.}): string =
  let (sql, bound) = bindWithNulls(sqlStr, args)
  getValueProc(db, SqlQuery(sql), bound)

proc runAffected*[Db](db: Db, sqlStr: string, args: seq[string],
                     execAffectedProc: proc (db: Db, query: SqlQuery, args: varargs[string, `$`]): int64 {.nimcall.}): int64 =
  let (sql, bound) = bindWithNulls(sqlStr, args)
  execAffectedProc(db, SqlQuery(sql), bound)
