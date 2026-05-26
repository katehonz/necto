## Necto Query
##
## Композируем type-safe query builder.
##
## Пример:
##   Query.fromSchema(User)
##     .where("age", Gte, "18")
##     .orderBy("name", Asc)
##     .limit(10)
##     .select("id", "name")

import std/[macros, strutils, options, tables, sequtils]
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

  SqlFragment* = object
    ## Raw SQL фрагмент с параметри.
    sql*: string
    args*: seq[string]

  SubQuery*[T] = object
    ## Подзаяка за IN и EXISTS.
    query*: Query[T]

  AggregateOp* = enum
    AggCount, AggSum, AggAvg, AggMin, AggMax

  AggregateClause* = object
    op*: AggregateOp
    field*: string
    alias*: string

  GroupByClause* = object
    fields*: seq[string]

  HavingClause* = object
    field*: string
    op*: WhereOp
    value*: string

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
    aggregates*: seq[AggregateClause]
    groupByFields*: seq[string]
    havingClauses*: seq[HavingClause]

  BoundQuery* = object
    ## SQL с $N placeholders + отделени аргументи.
    sql*: string
    args*: seq[string]

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

proc orWhere*[T](q: Query[T], field: string, op: WhereOp, value: string): Query[T] =
  ## Добавя условие с OR конюнкция.
  result = q
  result.whereClauses.add(WhereClause(field: field, op: op, value: value, conjunction: "OR"))

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

# --- Join операции ---

proc innerJoin*[T](q: Query[T], table: string, on: string): Query[T] =
  ## Добавя INNER JOIN.
  result = q
  result.joinClauses.add(JoinClause(joinType: "INNER", table: table, on: on))

proc leftJoin*[T](q: Query[T], table: string, on: string): Query[T] =
  ## Добавя LEFT JOIN.
  result = q
  result.joinClauses.add(JoinClause(joinType: "LEFT", table: table, on: on))

proc rightJoin*[T](q: Query[T], table: string, on: string): Query[T] =
  ## Добавя RIGHT JOIN.
  result = q
  result.joinClauses.add(JoinClause(joinType: "RIGHT", table: table, on: on))

proc fullJoin*[T](q: Query[T], table: string, on: string): Query[T] =
  ## Добавя FULL OUTER JOIN.
  result = q
  result.joinClauses.add(JoinClause(joinType: "FULL OUTER", table: table, on: on))

# --- Агрегати ---

proc count*[T](q: Query[T], field: string = "*", alias: string = "count"): Query[T] =
  ## Добавя COUNT агрегат.
  result = q
  result.aggregates.add(AggregateClause(op: AggCount, field: field, alias: alias))

proc sum*[T](q: Query[T], field: string, alias: string = ""): Query[T] =
  ## Добавя SUM агрегат.
  result = q
  let finalAlias = if alias.len > 0: alias else: field & "_sum"
  result.aggregates.add(AggregateClause(op: AggSum, field: field, alias: finalAlias))

proc avg*[T](q: Query[T], field: string, alias: string = ""): Query[T] =
  ## Добавя AVG агрегат.
  result = q
  let finalAlias = if alias.len > 0: alias else: field & "_avg"
  result.aggregates.add(AggregateClause(op: AggAvg, field: field, alias: finalAlias))

proc min*[T](q: Query[T], field: string, alias: string = ""): Query[T] =
  ## Добавя MIN агрегат.
  result = q
  let finalAlias = if alias.len > 0: alias else: field & "_min"
  result.aggregates.add(AggregateClause(op: AggMin, field: field, alias: finalAlias))

proc max*[T](q: Query[T], field: string, alias: string = ""): Query[T] =
  ## Добавя MAX агрегат.
  result = q
  let finalAlias = if alias.len > 0: alias else: field & "_max"
  result.aggregates.add(AggregateClause(op: AggMax, field: field, alias: finalAlias))

# --- Group By / Having ---

proc groupBy*[T](q: Query[T], fields: varargs[string]): Query[T] =
  ## Добавя GROUP BY.
  result = q
  result.groupByFields = @fields

proc having*[T](q: Query[T], field: string, op: WhereOp, value: string): Query[T] =
  ## Добавя HAVING условие.
  result = q
  result.havingClauses.add(HavingClause(field: field, op: op, value: value))

# --- Raw SQL фрагменти ---

proc fragment*(sql: string, args: varargs[string]): SqlFragment =
  ## Създава raw SQL фрагмент с $1, $2, ... параметри.
  ## Забележка: аргументите се съхраняват в SqlFragment но трябва да бъдат
  ## преномерирани и добавени към BoundQuery.args при генериране на SQL.
  result = SqlFragment(sql: sql, args: @args)

proc whereDynamic*[T](q: Query[T], frag: SqlFragment): Query[T] =
  ## Добавя raw SQL фрагмент като WHERE условие.
  result = q
  result.whereClauses.add(WhereClause(
    field: frag.sql,
    op: Eq,
    value: "",
    conjunction: "AND"
  ))

proc whereFragment*[T](q: Query[T], frag: SqlFragment): Query[T] =
  ## Добавя raw SQL фрагмент като WHERE условие.
  whereDynamic(q, frag)

# --- Subquery ---

proc subquery*[T](q: Query[T]): SubQuery[T] =
  ## Обръща Query в SubQuery за IN/EXISTS.
  SubQuery[T](query: q)

# --- SQL Генерация с parameter binding ---

template toBoundQuery*[T](q: Query[T]): BoundQuery =
  ## Превръща Query в SQL с `$N` placeholders + seq от стойности.
  ## Template за да резолвира schemaMeta(T) в scope-а на извикване.
  mixin schemaMeta
  let meta = schemaMeta(T)
  var parts: seq[string] = @[]
  var args: seq[string] = @[]
  var idx = 1

  parts.add("SELECT")
  if q.distinctVal:
    parts.add("DISTINCT")

  # Агрегати
  if q.aggregates.len > 0:
    var aggParts: seq[string] = @[]
    for agg in q.aggregates:
      case agg.op
      of AggCount:
        aggParts.add("COUNT(\"" & agg.field & "\") AS \"" & agg.alias & "\"")
      of AggSum:
        aggParts.add("SUM(\"" & agg.field & "\") AS \"" & agg.alias & "\"")
      of AggAvg:
        aggParts.add("AVG(\"" & agg.field & "\") AS \"" & agg.alias & "\"")
      of AggMin:
        aggParts.add("MIN(\"" & agg.field & "\") AS \"" & agg.alias & "\"")
      of AggMax:
        aggParts.add("MAX(\"" & agg.field & "\") AS \"" & agg.alias & "\"")
    parts.add(aggParts.join(", "))
  elif q.selectFields.len > 0:
    parts.add(q.selectFields.join(", "))
  else:
    parts.add("*")

  parts.add("FROM")
  parts.add("\"" & meta.tableName & "\"")

  # Joins
  if q.joinClauses.len > 0:
    for j in q.joinClauses:
      parts.add(j.joinType & " JOIN " & j.table & " ON " & j.on)

  if q.whereClauses.len > 0:
    parts.add("WHERE")
    var wheres: seq[string] = @[]
    var isFirst = true
    for w in q.whereClauses:
      if not isFirst:
        wheres.add(w.conjunction)
      isFirst = false

      if w.field.contains("$1") or w.field.contains("?") or w.field.contains("("):
        wheres.add(w.field)
      else:
        case w.op
        of Eq:
          wheres.add("\"" & w.field & "\" = $" & $idx)
          args.add(w.value)
          inc idx
        of Ne:
          wheres.add("\"" & w.field & "\" != $" & $idx)
          args.add(w.value)
          inc idx
        of Gt:
          wheres.add("\"" & w.field & "\" > $" & $idx)
          args.add(w.value)
          inc idx
        of Gte:
          wheres.add("\"" & w.field & "\" >= $" & $idx)
          args.add(w.value)
          inc idx
        of Lt:
          wheres.add("\"" & w.field & "\" < $" & $idx)
          args.add(w.value)
          inc idx
        of Lte:
          wheres.add("\"" & w.field & "\" <= $" & $idx)
          args.add(w.value)
          inc idx
        of Like:
          wheres.add("\"" & w.field & "\" LIKE $" & $idx)
          args.add(w.value)
          inc idx
        of Ilike:
          wheres.add("\"" & w.field & "\" ILIKE $" & $idx)
          args.add(w.value)
          inc idx
        of In:
          wheres.add("\"" & w.field & "\" IN ($" & $idx & ")")
          args.add(w.value)
          inc idx
        of IsNull:
          wheres.add("\"" & w.field & "\" IS NULL")
        of NotNull:
          wheres.add("\"" & w.field & "\" IS NOT NULL")
    parts.add(wheres.join(" "))

  if q.orderClauses.len > 0:
    parts.add("ORDER BY")
    var orders: seq[string] = @[]
    for o in q.orderClauses:
      let dirStr = if o.dir == Asc: "ASC" else: "DESC"
      orders.add("\"" & o.field & "\" " & dirStr)
    parts.add(orders.join(", "))

  # Group By
  if q.groupByFields.len > 0:
    parts.add("GROUP BY")
    parts.add(q.groupByFields.mapIt("\"" & it & "\"").join(", "))

  # Having
  if q.havingClauses.len > 0:
    parts.add("HAVING")
    var havings: seq[string] = @[]
    for h in q.havingClauses:
      case h.op
      of Eq:
        havings.add("\"" & h.field & "\" = $" & $idx)
        args.add(h.value)
        inc idx
      of Gt:
        havings.add("\"" & h.field & "\" > $" & $idx)
        args.add(h.value)
        inc idx
      of Gte:
        havings.add("\"" & h.field & "\" >= $" & $idx)
        args.add(h.value)
        inc idx
      of Lt:
        havings.add("\"" & h.field & "\" < $" & $idx)
        args.add(h.value)
        inc idx
      of Lte:
        havings.add("\"" & h.field & "\" <= $" & $idx)
        args.add(h.value)
        inc idx
      else:
        havings.add("\"" & h.field & "\"")
    parts.add(havings.join(" AND "))

  if q.limitVal.isSome:
    parts.add("LIMIT $" & $idx)
    args.add($q.limitVal.get)
    inc idx

  if q.offsetVal.isSome:
    parts.add("OFFSET $" & $idx)
    args.add($q.offsetVal.get)
    inc idx

  BoundQuery(sql: parts.join(" "), args: args)

template toSql*[T](q: Query[T]): string =
  ## Само SQL низ (без аргументи). За debug/legacy употреба.
  toBoundQuery(q).sql

# --- Макро за type-safe where ---

type
  WhereItClause = object
    field: string
    op: string
    value: NimNode
    conjunction: string  # "AND" / "OR"

type WhereItClauseSeq = seq[WhereItClause]

proc nimOpToWhereOp(opStr: string): NimNode {.compileTime.} =
  case opStr
  of "==": newIdentNode("Eq")
  of "!=": newIdentNode("Ne")
  of ">": newIdentNode("Gt")
  of ">=": newIdentNode("Gte")
  of "<": newIdentNode("Lt")
  of "<=": newIdentNode("Lte")
  else: newIdentNode("Eq")

proc extractClauses(expr: NimNode, clauses: var WhereItClauseSeq, conj: string = "AND") =
  case expr.kind
  of nnkInfix:
    let opStr = $expr[0]
    if opStr in ["and", "or"]:
      extractClauses(expr[1], clauses, conj)
      extractClauses(expr[2], clauses, opStr.toUpperAscii())
    elif opStr in ["==", "!=", ">", "<", ">=", "<="]:
      let fieldNode = expr[1]
      let valueNode = expr[2]
      if fieldNode.kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $fieldNode,
          op: opStr,
          value: valueNode,
          conjunction: conj
        ))
  of nnkCall, nnkCommand:
    let fnName = $expr[0]
    if fnName == "like":
      if expr.len >= 3 and expr[1].kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $expr[1], op: "like", value: expr[2], conjunction: conj
        ))
    elif fnName == "ilike":
      if expr.len >= 3 and expr[1].kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $expr[1], op: "ilike", value: expr[2], conjunction: conj
        ))
    elif fnName in ["isNil", "is_nil"]:
      if expr.len >= 2 and expr[1].kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $expr[1], op: "is_null", value: newEmptyNode(), conjunction: conj
        ))
    elif fnName in ["isNotNil", "is_not_nil"]:
      if expr.len >= 2 and expr[1].kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $expr[1], op: "not_null", value: newEmptyNode(), conjunction: conj
        ))
    elif fnName == "not":
      if expr.len >= 2 and expr[1].kind == nnkCall and $expr[1][0] in ["isNil", "is_nil"]:
        if expr[1].len >= 2 and expr[1][1].kind == nnkIdent:
          clauses.add(WhereItClause(
            field: $expr[1][1], op: "not_null", value: newEmptyNode(), conjunction: conj
          ))
  of nnkPrefix:
    let opStr = $expr[0]
    if opStr == "not":
      if expr[1].kind == nnkIdent:
        clauses.add(WhereItClause(
          field: $expr[1], op: "is_null", value: newEmptyNode(), conjunction: conj
        ))
      else:
        extractClauses(expr[1], clauses, conj)
  else:
    discard

proc validateFieldsAgainstSchema(fieldNames: seq[string], schemaFields: seq[string]) {.compileTime.} =
  for fname in fieldNames:
    if fname notin schemaFields:
      error("Unknown field '" & fname & "' in whereIt. Available fields: " & schemaFields.join(", "))

proc generateWhereCall(clause: WhereItClause, q: NimNode): NimNode {.compileTime.} =
  let fieldLit = newLit(clause.field)
  let opNode = nimOpToWhereOp(clause.op)
  case clause.op
  of "is_null":
    quote do:
      `q`.where(`fieldLit`, IsNull, "")
  of "not_null":
    quote do:
      `q`.where(`fieldLit`, NotNull, "")
  of "in":
    let valExp = newCall(newIdentNode("$"), clause.value)
    quote do:
      `q`.where(`fieldLit`, In, `valExp`)
  of "like":
    let valExp = newCall(newIdentNode("$"), clause.value)
    quote do:
      `q`.where(`fieldLit`, Like, `valExp`)
  of "ilike":
    let valExp = newCall(newIdentNode("$"), clause.value)
    quote do:
      `q`.where(`fieldLit`, Ilike, `valExp`)
  else:
    let valExp = if clause.value.kind in {nnkStrLit, nnkRStrLit}:
      clause.value
    else:
      newCall(newIdentNode("$"), clause.value)
    quote do:
      `q`.where(`fieldLit`, `opNode`, `valExp`)

macro whereIt*(q: typed, expr: untyped): untyped =
  let qType = q.getTypeInst()
  var schemaType: NimNode
  if qType.kind == nnkBracketExpr and qType[0].strVal == "Query":
    schemaType = qType[1]
  else:
    error("whereIt expects a Query[T], got: " & qType.repr)

  var clauses: WhereItClauseSeq = @[]
  extractClauses(expr, clauses)

  var fieldNames: seq[string] = @[]
  for c in clauses:
    fieldNames.add(c.field)

  result = newStmtList()

  let checkBlock = quote do:
    static:
      let meta = schemaMeta(`schemaType`)
      var names: seq[string] = @[]
      for f in meta.fields:
        names.add(f.name)
      validateFieldsAgainstSchema(`fieldNames`, names)

  result.add(checkBlock)

  var chain = q
  for c in clauses:
    chain = generateWhereCall(c, chain)
  result.add(chain)
