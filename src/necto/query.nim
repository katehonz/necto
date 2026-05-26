## Necto Query
##
## Композируем type-safe query builder.
##
## Пример:
##   Query.fromSchema(User)
##     .where(it.age >= 18)
##     .order_by(it.name.asc)
##     .limit(10)
##     .select(it.id, it.name)

import std/[macros, strutils, options, tables]
import ./schema

export schema

type
  OrderDirection* = enum
    Asc, Desc

  WhereOp* = enum
    Eq, Ne, Gt, Gte, Lt, Lte, Like, Ilike, In, IsNull, NotNull

  WhereClause* = object
    field*: string
    op*: WhereOp
    value*: string
    conjunction*: string  # "AND" | "OR"

  OrderClause* = object
    field*: string
    dir*: OrderDirection

  JoinClause* = object
    joinType*: string     # "INNER", "LEFT"
    table*: string
    on*: string

  Query*[T] = object
    ## Структура, която натрупва SQL фрагменти.
    selectFields*: seq[string]
    whereClauses*: seq[WhereClause]
    orderClauses*: seq[OrderClause]
    joinClauses*: seq[JoinClause]
    limitVal*: Option[int]
    offsetVal*: Option[int]
    distinctVal*: bool
    preloadAssocs*: seq[string]

# --- Конструктори ---

proc fromSchema*[T](typ: typedesc[T]): Query[T] =
  ## Започва нова заявка за даден Schema.
  Query[T](selectFields: @[])

# --- Модификатори (immutable клониране) ---

proc select*[T](q: Query[T], fields: varargs[string]): Query[T] =
  result = q
  result.selectFields = @fields

proc where*[T](q: Query[T], field: string, op: WhereOp, value: string): Query[T] =
  result = q
  result.whereClauses.add(WhereClause(field: field, op: op, value: value, conjunction: "AND"))

proc orderBy*[T](q: Query[T], field: string, dir: OrderDirection = Asc): Query[T] =
  result = q
  result.orderClauses.add(OrderClause(field: field, dir: dir))

proc limit*[T](q: Query[T], n: int): Query[T] =
  result = q
  result.limitVal = some(n)

proc offset*[T](q: Query[T], n: int): Query[T] =
  result = q
  result.offsetVal = some(n)

proc setDistinct*[T](q: Query[T]): Query[T] =
  result = q
  result.distinctVal = true

proc preload*[T](q: Query[T], assoc: string): Query[T] =
  result = q
  result.preloadAssocs.add(assoc)

# --- SQL Генерация (placeholder за query_builder.nim) ---

proc toSql*[T](q: Query[T]): string =
  ## Превръща Query в SQL низ. За MVP — опростена имплементация.
  let meta = schemaMeta(T)
  var parts: seq[string] = @[]

  parts.add("SELECT")
  if q.distinctVal:
    parts.add("DISTINCT")

  if q.selectFields.len > 0:
    parts.add(q.selectFields.join(", "))
  else:
    parts.add("*")

  parts.add("FROM")
  parts.add(meta.tableName)

  if q.whereClauses.len > 0:
    parts.add("WHERE")
    var wheres: seq[string] = @[]
    var idx = 1
    for w in q.whereClauses:
      let placeholder = "$" & $idx
      case w.op
      of Eq: wheres.add(w.field & " = " & placeholder)
      of Ne: wheres.add(w.field & " != " & placeholder)
      of Gt: wheres.add(w.field & " > " & placeholder)
      of Gte: wheres.add(w.field & " >= " & placeholder)
      of Lt: wheres.add(w.field & " < " & placeholder)
      of Lte: wheres.add(w.field & " <= " & placeholder)
      of Like: wheres.add(w.field & " LIKE " & placeholder)
      of Ilike: wheres.add(w.field & " ILIKE " & placeholder)
      of In: wheres.add(w.field & " IN (" & placeholder & ")")
      of IsNull: wheres.add(w.field & " IS NULL")
      of NotNull: wheres.add(w.field & " IS NOT NULL")
      inc idx
    parts.add(wheres.join(" AND "))

  if q.orderClauses.len > 0:
    parts.add("ORDER BY")
    var orders: seq[string] = @[]
    for o in q.orderClauses:
      let dirStr = if o.dir == Asc: "ASC" else: "DESC"
      orders.add(o.field & " " & dirStr)
    parts.add(orders.join(", "))

  if q.limitVal.isSome:
    parts.add("LIMIT " & $q.limitVal.get)

  if q.offsetVal.isSome:
    parts.add("OFFSET " & $q.offsetVal.get)

  parts.join(" ")

# --- Макро за type-safe where (бъдеще) ---
##
## Идея:
##   Query.from(User).where(it.age >= 18)
##
## Nim макро ще трансформира `it.age >= 18` в:
##   where("age", Gte, "18")
## с type checking по време на компилация.

macro whereIt*(q: untyped, expr: untyped): untyped =
  ## Placeholder за бъдещо `it` захващане.
  result = q
