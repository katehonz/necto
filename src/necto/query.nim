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
    Eq, Ne, Gt, Gte, Lt, Lte, Like, Ilike, In, IsNull, NotNull, Raw

  WhereClause* = object
    field*: string
    op*: WhereOp
    value*: string
    conjunction*: string  # "AND" | "OR"
    fragmentArgs*: seq[string]  # args from SqlFragment
    isRawField*: bool  ## Ако true, `field` се използва директно без кавички (SQL израз).

  OrderClause* = object
    field*: string
    dir*: OrderDirection
    fragmentArgs*: seq[string]  ## args for raw SQL expressions
    isRawField*: bool  ## If true, field is used directly without quoting

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
    conjunction*: string  ## "AND" | "OR"
    fragmentArgs*: seq[string]  ## args from SqlFragment
    isRawField*: bool  ## Ако true, `field` се използва директно без кавички.

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
    includeDeletedVal*: bool  ## За soft deletes: включва изтрити редове
    windowFunctions*: seq[string]  ## Window function SQL изрази

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
  result.selectFields = @[]
  for f in fields:
    let qf = if f.contains(".") or f.contains("(") or f.contains("#") or f.contains("@") or f.contains("?"): f else: "\"" & f & "\""
    result.selectFields.add(qf)

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

proc orderByRaw*[T](q: Query[T], fieldExpr: string, args: varargs[string],
                    dir: OrderDirection = Asc): Query[T] =
  ## ORDER BY с raw SQL израз и parameter binding.
  ## Полезно за ts_rank, window functions и др.
  result = q
  result.orderClauses.add(OrderClause(
    field: fieldExpr, dir: dir, fragmentArgs: @args, isRawField: true
  ))

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

proc includeDeleted*[T](q: Query[T]): Query[T] =
  ## Включва soft-deleted редове в резултатите.
  result = q
  result.includeDeletedVal = true

proc onlyDeleted*[T](q: Query[T]): Query[T] =
  ## Връща само soft-deleted редове.
  result = q
  result.includeDeletedVal = true
  result.whereClauses.add(WhereClause(
    field: "deleted_at", op: NotNull, value: "", conjunction: "AND"
  ))

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

# --- Window functions ---

proc buildOverClause(partitionBy: openArray[string], orderByField: string, orderDir: OrderDirection): string =
  ## Генерира OVER() SQL клауза.
  var parts: seq[string] = @[]
  if partitionBy.len > 0:
    parts.add("PARTITION BY " & partitionBy.mapIt("\"" & it & "\"").join(", "))
  if orderByField.len > 0:
    let dirStr = if orderDir == Asc: "ASC" else: "DESC"
    parts.add("ORDER BY \"" & orderByField & "\" " & dirStr)
  result = "OVER (" & parts.join(" ") & ")"

proc rowNumber*[T](q: Query[T], partitionBy: openArray[string] = [],
                   orderByField: string = "", orderDir: OrderDirection = Asc,
                   alias: string = "row_num"): Query[T] =
  ## Добавя ROW_NUMBER() window function.
  ## Пример: q.rowNumber(partitionBy = ["dept"], orderByField = "salary", orderDir = Desc)
  result = q
  let over = buildOverClause(partitionBy, orderByField, orderDir)
  result.windowFunctions.add("ROW_NUMBER() " & over & " AS \"" & alias & "\"")

proc rank*[T](q: Query[T], partitionBy: openArray[string] = [],
              orderByField: string = "", orderDir: OrderDirection = Asc,
              alias: string = "rank"): Query[T] =
  ## Добавя RANK() window function.
  result = q
  let over = buildOverClause(partitionBy, orderByField, orderDir)
  result.windowFunctions.add("RANK() " & over & " AS \"" & alias & "\"")

proc denseRank*[T](q: Query[T], partitionBy: openArray[string] = [],
                   orderByField: string = "", orderDir: OrderDirection = Asc,
                   alias: string = "dense_rank"): Query[T] =
  ## Добавя DENSE_RANK() window function.
  result = q
  let over = buildOverClause(partitionBy, orderByField, orderDir)
  result.windowFunctions.add("DENSE_RANK() " & over & " AS \"" & alias & "\"")

proc lag*[T](q: Query[T], field: string, offset: int = 1,
             partitionBy: openArray[string] = [],
             orderByField: string = "", orderDir: OrderDirection = Asc,
             alias: string = ""): Query[T] =
  ## Добавя LAG(field, offset) window function.
  result = q
  let over = buildOverClause(partitionBy, orderByField, orderDir)
  let defaultAlias = if alias.len > 0: alias else: field & "_lag"
  result.windowFunctions.add("LAG(\"" & field & "\", " & $offset & ") " & over & " AS \"" & defaultAlias & "\"")

proc lead*[T](q: Query[T], field: string, offset: int = 1,
              partitionBy: openArray[string] = [],
              orderByField: string = "", orderDir: OrderDirection = Asc,
              alias: string = ""): Query[T] =
  ## Добавя LEAD(field, offset) window function.
  result = q
  let over = buildOverClause(partitionBy, orderByField, orderDir)
  let defaultAlias = if alias.len > 0: alias else: field & "_lead"
  result.windowFunctions.add("LEAD(\"" & field & "\", " & $offset & ") " & over & " AS \"" & defaultAlias & "\"")

# --- Group By / Having ---

proc groupBy*[T](q: Query[T], fields: varargs[string]): Query[T] =
  ## Добавя GROUP BY.
  result = q
  result.groupByFields = @fields

proc having*[T](q: Query[T], field: string, op: WhereOp, value: string; conjunction: string = "AND"): Query[T] =
  ## Добавя HAVING условие.
  result = q
  result.havingClauses.add(HavingClause(field: field, op: op, value: value, conjunction: conjunction, fragmentArgs: @[]))

# --- Raw SQL фрагменти ---

proc fragment*(sql: string, args: varargs[string]): SqlFragment =
  ## Създава raw SQL фрагмент с $1, $2, ... параметри.
  ## Забележка: аргументите се съхраняват в SqlFragment но трябва да бъдат
  ## преномерирани и добавени към BoundQuery.args при генериране на SQL.
  result = SqlFragment(sql: sql, args: @args)

proc whereDynamic*[T](q: Query[T], frag: SqlFragment): Query[T] =
  ## Добавя raw SQL фрагмент като WHERE условие.
  ## Placeholders `$1`, `$2` … във фрагмента се преномерират автоматично
  ## при генериране на SQL (`toBoundQuery`).
  result = q
  result.whereClauses.add(WhereClause(
    field: frag.sql,
    op: Eq,
    value: "",
    conjunction: "AND",
    fragmentArgs: frag.args
  ))

proc whereFragment*[T](q: Query[T], frag: SqlFragment): Query[T] =
  ## Добавя raw SQL фрагмент като WHERE условие.
  whereDynamic(q, frag)

# --- JSONB helpers ---

template jsonbContains*(field: string, json: string): SqlFragment =
  ## PostgreSQL `@>` оператор: jsonb съдържа даден обект.
  ## Пример: `whereDynamic(q, jsonbContains("profile", "{\"verified\":true}"))`
  fragment("\"" & field & "\" @> $1", json)

template jsonbHasKey*(field: string, key: string): SqlFragment =
  ## PostgreSQL `?` оператор: jsonb има даден ключ.
  fragment("\"" & field & "\" ? $1", key)

template jsonbHasAnyKeys*(field: string, keys: openArray[string]): SqlFragment =
  ## PostgreSQL `?|` оператор: jsonb има поне един от ключовете.
  fragment("\"" & field & "\" ?| $1", "{" & keys.join(",") & "}")

template jsonbHasAllKeys*(field: string, keys: openArray[string]): SqlFragment =
  ## PostgreSQL `?&` оператор: jsonb има всички ключове.
  fragment("\"" & field & "\" ?& $1", "{" & keys.join(",") & "}")

proc jsonbPathText*(field: string, path: openArray[string]): string =
  ## Връща SQL израз `field #>> '{path}'` за text extraction.
  ## Може да се използва с `whereRawField`.
  result = "\"" & field & "\" #>> '{" & path.join(",") & "}'"

proc jsonbPath*(field: string, path: openArray[string]): string =
  ## Връща SQL израз `field #> '{path}'` за JSON extraction.
  result = "\"" & field & "\" #> '{" & path.join(",") & "}'"

proc whereRawField*[T](q: Query[T], fieldExpr: string, op: WhereOp, value: string;
                       conjunction: string = "AND"): Query[T] =
  ## WHERE условие с raw SQL израз за поле (без автоматични кавички).
  ## Полезно за JSONB path оператори и др.
  ## Пример: `q.whereRawField(jsonbPathText("profile", ["settings","theme"]), Eq, "dark")`
  result = q
  result.whereClauses.add(WhereClause(
    field: fieldExpr, op: op, value: value, conjunction: conjunction, isRawField: true
  ))

proc orWhereRawField*[T](q: Query[T], fieldExpr: string, op: WhereOp, value: string): Query[T] =
  ## OR WHERE условие с raw SQL израз за поле.
  result = q
  result.whereClauses.add(WhereClause(
    field: fieldExpr, op: op, value: value, conjunction: "OR", isRawField: true
  ))

# --- Convenience JSONB where methods ---

proc whereJsonbContains*[T](q: Query[T], field: string, json: string): Query[T] =
  ## WHERE field @> json
  whereDynamic(q, jsonbContains(field, json))

proc whereJsonbHasKey*[T](q: Query[T], field: string, key: string): Query[T] =
  ## WHERE field ? key
  whereDynamic(q, jsonbHasKey(field, key))

proc whereJsonbHasAnyKeys*[T](q: Query[T], field: string, keys: openArray[string]): Query[T] =
  ## WHERE field ?| keys
  whereDynamic(q, jsonbHasAnyKeys(field, keys))

proc whereJsonbHasAllKeys*[T](q: Query[T], field: string, keys: openArray[string]): Query[T] =
  ## WHERE field ?& keys
  whereDynamic(q, jsonbHasAllKeys(field, keys))

# --- Subquery ---

proc subquery*[T](q: Query[T]): SubQuery[T] =
  ## Обръща Query в SubQuery за IN/EXISTS.
  SubQuery[T](query: q)

template toSubqueryFragment*[T](sq: SubQuery[T]): SqlFragment =
  ## Превръща SubQuery в SqlFragment за вграждане в WHERE/HAVING.
  ## Placeholders се преномерират автоматично от toBoundQuery.
  let bq = sq.query.toBoundQuery()
  fragment("(" & bq.sql & ")", bq.args)

# --- Subquery WHERE helpers ---

proc whereIn*[T](q: Query[T], field: string, sq: SubQuery[auto]): Query[T] =
  ## WHERE field IN (subquery).
  result = q
  let frag = sq.toSubqueryFragment()
  result.whereClauses.add(WhereClause(
    field: "\"" & field & "\" IN " & frag.sql,
    op: Raw,
    value: "",
    conjunction: "AND",
    fragmentArgs: frag.args,
    isRawField: true
  ))

proc whereNotIn*[T](q: Query[T], field: string, sq: SubQuery[auto]): Query[T] =
  ## WHERE field NOT IN (subquery).
  result = q
  let frag = sq.toSubqueryFragment()
  result.whereClauses.add(WhereClause(
    field: "\"" & field & "\" NOT IN " & frag.sql,
    op: Raw,
    value: "",
    conjunction: "AND",
    fragmentArgs: frag.args,
    isRawField: true
  ))

proc whereExists*[T](q: Query[T], sq: SubQuery[auto]): Query[T] =
  ## WHERE EXISTS (subquery).
  result = q
  let frag = sq.toSubqueryFragment()
  result.whereClauses.add(WhereClause(
    field: "EXISTS " & frag.sql,
    op: Raw,
    value: "",
    conjunction: "AND",
    fragmentArgs: frag.args,
    isRawField: true
  ))

proc whereNotExists*[T](q: Query[T], sq: SubQuery[auto]): Query[T] =
  ## WHERE NOT EXISTS (subquery).
  result = q
  let frag = sq.toSubqueryFragment()
  result.whereClauses.add(WhereClause(
    field: "NOT EXISTS " & frag.sql,
    op: Raw,
    value: "",
    conjunction: "AND",
    fragmentArgs: frag.args,
    isRawField: true
  ))

# --- FTS (Full-Text Search) helpers ---

template toTsVector*(lang: string, field: string): string =
  ## SQL fragment: to_tsvector('lang', "field")
  "to_tsvector('" & lang & "', \"" & field & "\")"

template plaintoTsQuery*(lang: string, query: string): SqlFragment =
  ## SQL fragment: plainto_tsquery('lang', $1)
  fragment("plainto_tsquery('" & lang & "', $1)", query)

template phrasetoTsQuery*(lang: string, query: string): SqlFragment =
  ## SQL fragment: phraseto_tsquery('lang', $1)
  fragment("phraseto_tsquery('" & lang & "', $1)", query)

template websearchToTsQuery*(lang: string, query: string): SqlFragment =
  ## SQL fragment: websearch_to_tsquery('lang', $1)
  fragment("websearch_to_tsquery('" & lang & "', $1)", query)

template toTsQuery*(lang: string, query: string): SqlFragment =
  ## SQL fragment: to_tsquery('lang', $1)
  fragment("to_tsquery('" & lang & "', $1)", query)

proc whereTsVectorMatches*[T](q: Query[T], field: string, tsq: SqlFragment;
                               conjunction: string = "AND"): Query[T] =
  ## WHERE "field" @@ tsquery — full-text match.
  ## Пример: q.whereTsVectorMatches("search_vector", plaintoTsQuery("simple", "nim orm"))
  result = q
  let qf = if field.contains("("): field else: "\"" & field & "\""
  result.whereClauses.add(WhereClause(
    field: qf & " @@ " & tsq.sql,
    op: Raw,
    value: "",
    conjunction: conjunction,
    fragmentArgs: tsq.args,
    isRawField: true
  ))

proc orWhereTsVectorMatches*[T](q: Query[T], field: string, tsq: SqlFragment): Query[T] =
  ## OR WHERE "field" @@ tsquery.
  result = q.whereTsVectorMatches(field, tsq, "OR")

template tsRank*(fieldExpr: string, tsq: SqlFragment): SqlFragment =
  ## SQL fragment: ts_rank(field, tsquery)
  fragment("ts_rank(" & fieldExpr & ", " & tsq.sql & ")", tsq.args)

template tsRankCd*(fieldExpr: string, tsq: SqlFragment): SqlFragment =
  ## SQL fragment: ts_rank_cd(field, tsquery)
  fragment("ts_rank_cd(" & fieldExpr & ", " & tsq.sql & ")", tsq.args)

proc orderByTsRank*[T](q: Query[T], field: string, tsq: SqlFragment,
                       dir: OrderDirection = Desc): Query[T] =
  ## ORDER BY ts_rank("field", tsquery) DIR.
  ## Ползва orderByRaw за parameter binding.
  ## Ако field е text колона, ползвайте toTsVector() ръчно:
  ##   q.orderByTsRank(toTsVector("simple", "content"), plaintoTsQuery(...))
  result = q
  let qf = if field.contains("("): field else: "\"" & field & "\""
  let frag = tsRank(qf, tsq)
  result.orderClauses.add(OrderClause(
    field: frag.sql, dir: dir, fragmentArgs: frag.args, isRawField: true
  ))

proc orderByTsRankCd*[T](q: Query[T], field: string, tsq: SqlFragment,
                         dir: OrderDirection = Desc): Query[T] =
  ## ORDER BY ts_rank_cd("field", tsquery) DIR.
  result = q
  let qf = if field.contains("("): field else: "\"" & field & "\""
  let frag = tsRankCd(qf, tsq)
  result.orderClauses.add(OrderClause(
    field: frag.sql, dir: dir, fragmentArgs: frag.args, isRawField: true
  ))

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
    var selectParts = q.selectFields
    for wf in q.windowFunctions:
      selectParts.add(wf)
    parts.add(selectParts.join(", "))
  elif q.windowFunctions.len > 0:
    parts.add(q.windowFunctions.join(", "))
  else:
    parts.add("*")

  parts.add("FROM")
  parts.add("\"" & meta.tableName & "\"")

  # Joins
  if q.joinClauses.len > 0:
    for j in q.joinClauses:
      parts.add(j.joinType & " JOIN " & j.table & " ON " & j.on)

  var hasWhere = q.whereClauses.len > 0 or (meta.softDeletes and not q.includeDeletedVal)
  if hasWhere:
    parts.add("WHERE")
    var wheres: seq[string] = @[]
    var isFirst = true

    # Soft delete filter
    if meta.softDeletes and not q.includeDeletedVal:
      wheres.add("\"deleted_at\" IS NULL")
      isFirst = false

    for w in q.whereClauses:
      if not isFirst:
        wheres.add(w.conjunction)
      isFirst = false

      proc quoteField(f: string): string =
        if f.contains(".") or f.contains("(") or f.contains("#") or f.contains("@") or f.contains("?"):
          f
        else:
          "\"" & f & "\""

      if w.isRawField:
        case w.op
        of Eq:
          wheres.add(w.field & " = $" & $idx); args.add(w.value); inc idx
        of Ne:
          wheres.add(w.field & " != $" & $idx); args.add(w.value); inc idx
        of Gt:
          wheres.add(w.field & " > $" & $idx); args.add(w.value); inc idx
        of Gte:
          wheres.add(w.field & " >= $" & $idx); args.add(w.value); inc idx
        of Lt:
          wheres.add(w.field & " < $" & $idx); args.add(w.value); inc idx
        of Lte:
          wheres.add(w.field & " <= $" & $idx); args.add(w.value); inc idx
        of Like:
          wheres.add(w.field & " LIKE $" & $idx); args.add(w.value); inc idx
        of Ilike:
          wheres.add(w.field & " ILIKE $" & $idx); args.add(w.value); inc idx
        of In:
          wheres.add(w.field & " IN ($" & $idx & ")"); args.add(w.value); inc idx
        of IsNull:
          wheres.add(w.field & " IS NULL")
        of NotNull:
          wheres.add(w.field & " IS NOT NULL")
        of Raw:
          var fragSql = w.field
          for i in countdown(w.fragmentArgs.len, 1):
            fragSql = fragSql.replace("$" & $i, "$" & $(idx + i - 1))
          for arg in w.fragmentArgs:
            args.add(arg)
            inc idx
          wheres.add(fragSql)
      elif w.fragmentArgs.len > 0:
        # Фрагмент с placeholders — преномерираме $1, $2 …
        var fragSql = w.field
        for i in countdown(w.fragmentArgs.len, 1):
          fragSql = fragSql.replace("$" & $i, "$" & $(idx + i - 1))
        for arg in w.fragmentArgs:
          args.add(arg)
          inc idx
        wheres.add(fragSql)
      else:
        let qf = quoteField(w.field)
        case w.op
        of Eq:
          wheres.add(qf & " = $" & $idx); args.add(w.value); inc idx
        of Ne:
          wheres.add(qf & " != $" & $idx); args.add(w.value); inc idx
        of Gt:
          wheres.add(qf & " > $" & $idx); args.add(w.value); inc idx
        of Gte:
          wheres.add(qf & " >= $" & $idx); args.add(w.value); inc idx
        of Lt:
          wheres.add(qf & " < $" & $idx); args.add(w.value); inc idx
        of Lte:
          wheres.add(qf & " <= $" & $idx); args.add(w.value); inc idx
        of Like:
          wheres.add(qf & " LIKE $" & $idx); args.add(w.value); inc idx
        of Ilike:
          wheres.add(qf & " ILIKE $" & $idx); args.add(w.value); inc idx
        of In:
          wheres.add(qf & " IN ($" & $idx & ")"); args.add(w.value); inc idx
        of IsNull:
          wheres.add(qf & " IS NULL")
        of NotNull:
          wheres.add(qf & " IS NOT NULL")
        of Raw:
          var fragSql = w.field
          for i in countdown(w.fragmentArgs.len, 1):
            fragSql = fragSql.replace("$" & $i, "$" & $idx)
            args.add(w.fragmentArgs[i-1])
            inc idx
          wheres.add(fragSql)
    parts.add(wheres.join(" "))

  if q.orderClauses.len > 0:
    parts.add("ORDER BY")
    var orders: seq[string] = @[]
    for o in q.orderClauses:
      let dirStr = if o.dir == Asc: "ASC" else: "DESC"
      if o.isRawField and o.fragmentArgs.len > 0:
        var fragSql = o.field
        for i in countdown(o.fragmentArgs.len, 1):
          fragSql = fragSql.replace("$" & $i, "$" & $(idx + i - 1))
        for arg in o.fragmentArgs:
          args.add(arg)
          inc idx
        orders.add(fragSql & " " & dirStr)
      elif o.isRawField:
        orders.add(o.field & " " & dirStr)
      else:
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
      let qf = if h.isRawField: h.field else: "\"" & h.field & "\""
      case h.op
      of Eq:
        havings.add(qf & " = $" & $idx); args.add(h.value); inc idx
      of Ne:
        havings.add(qf & " != $" & $idx); args.add(h.value); inc idx
      of Gt:
        havings.add(qf & " > $" & $idx); args.add(h.value); inc idx
      of Gte:
        havings.add(qf & " >= $" & $idx); args.add(h.value); inc idx
      of Lt:
        havings.add(qf & " < $" & $idx); args.add(h.value); inc idx
      of Lte:
        havings.add(qf & " <= $" & $idx); args.add(h.value); inc idx
      of Like:
        havings.add(qf & " LIKE $" & $idx); args.add(h.value); inc idx
      of Ilike:
        havings.add(qf & " ILIKE $" & $idx); args.add(h.value); inc idx
      of In:
        havings.add(qf & " IN ($" & $idx & ")"); args.add(h.value); inc idx
      of IsNull:
        havings.add(qf & " IS NULL")
      of NotNull:
        havings.add(qf & " IS NOT NULL")
      of Raw:
        var fragSql = h.field
        for i in countdown(h.fragmentArgs.len, 1):
          fragSql = fragSql.replace("$" & $i, "$" & $(idx + i - 1))
        for arg in h.fragmentArgs:
          args.add(arg)
          inc idx
        havings.add(fragSql)
    var havingParts: seq[string] = @[]
    for i, h in havings:
      if i > 0:
        havingParts.add(q.havingClauses[i].conjunction)
      havingParts.add(h)
    parts.add(havingParts.join(" "))

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

# --- JSONB type-safe where macro ---

proc extractJsonbPath(expr: NimNode): tuple[rootField: string, path: seq[string], op: string, value: NimNode] {.compileTime.} =
  ## Извлича JSONB път от израз като `profile.settings.theme == "dark"`.
  if expr.kind != nnkInfix:
    error("whereJsonbIt expects an infix expression like profile.settings.theme == 'dark'")
  result.op = $expr[0]
  result.value = expr[2]
  var pathExpr = expr[1]
  var path: seq[string] = @[]
  while pathExpr.kind == nnkDotExpr:
    path.insert($pathExpr[1], 0)
    pathExpr = pathExpr[0]
  if pathExpr.kind == nnkIdent:
    path.insert($pathExpr, 0)
  else:
    error("Invalid JSONB path expression: expected dot-access like profile.settings.theme")
  if path.len < 2:
    error("JSONB path must have at least one nested field, got: " & path.join("."))
  result.rootField = path[0]
  result.path = path[1..^1]

macro whereJsonbIt*(q: typed, expr: untyped): untyped =
  ## Type-safe JSONB path where.
  ## Пример: `q.whereJsonbIt(profile.settings.theme == "dark")`
  ## Генерира: `q.whereRawField(jsonbPathText("profile", ["settings","theme"]), Eq, "dark")`
  let qType = q.getTypeInst()
  var schemaType: NimNode
  if qType.kind == nnkBracketExpr and qType[0].strVal == "Query":
    schemaType = qType[1]
  else:
    error("whereJsonbIt expects a Query[T], got: " & qType.repr)

  let (rootField, path, opStr, valueNode) = extractJsonbPath(expr)
  let opNode = nimOpToWhereOp(opStr)

  let rootFieldLit = newLit(rootField)
  let pathLit = newLit(path)

  # Build the value expression
  let valExp = if valueNode.kind in {nnkStrLit, nnkRStrLit}:
    valueNode
  else:
    newCall(newIdentNode("$"), valueNode)

  let whereCall = quote do:
    `q`.whereRawField(jsonbPathText(`rootFieldLit`, `pathLit`), `opNode`, `valExp`)

  result = newStmtList()
  result.add(whereCall)

# --- Compiled Query Cache (Nim Superpower) ---

proc compileQuery*[T](q: Query[T]): BoundQuery =
  ## Pre-computes a query's SQL. Cache the result in a `let` for repeated use.
  ## For static queries, this avoids re-computing the SQL string.
  ##
  ## Usage:
  ##   let allUsersQ = compileQuery(fromSchema(User).orderBy("name", Asc))
  ##   echo allUsersQ.sql   # "SELECT * FROM \"users\" ORDER BY \"name\" ASC"
  q.toBoundQuery()

proc querySql*[T](q: Query[T]): string =
  ## Returns just the SQL string with all placeholders resolved to NULL.
  ## Useful for EXPLAIN verification and debugging.
  var bq = q.toBoundQuery()
  for i in 1..30:
    bq.sql = bq.sql.replace("$" & $i, "NULL")
  bq.sql

# --- Pipe operator for query pipelining (Elixir-style) ---

macro `|>`*(left: untyped; right: untyped): untyped =
  ## Pipe operator за query chaining.
  ## Пример: User |> fromSchema |> where("age", Gte, "18") |> repo.all
  if right.kind in {nnkCall, nnkCommand}:
    result = right
    result.insert(1, left)
  elif right.kind == nnkInfix:
    result = newCall(right, left)
  else:
    result = newCall(right, left)

