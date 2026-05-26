## Necto Schema
##
## Дефиниране на модели чрез `necto_schema` макрото.
## Генерира ref object тип, SchemaMeta за reflection,
## конструктор и row loader за преобразуване на DbRow → обект.
##
## Пример:
##   necto_schema User:
##     table "users"
##     field id: int64 {.primary_key.}
##     field name: string
##     field email: string
##     timestamps
##     changeset register(params):
##       this |> castFields(params, @["name", "email"]) |> validateRequired(@["name", "email"])

import std/[macros, tables, strutils, times]
import ./type_system
import ./adapters/base

export type_system, base, times

# --- Schema Metadata ---

type
  FieldMeta* = object
    name*: string
    dbColumn*: string
    nimType*: string
    dbType*: string
    primaryKey*: bool
    autoIncrement*: bool
    nullable*: bool
    unique*: bool
    defaultValue*: string
    virtual*: bool
    isTimestamp*: bool

  AssocKind* = enum
    akBelongsTo, akHasMany, akHasOne

  AssocMeta* = object
    name*: string
    kind*: AssocKind
    targetSchema*: string
    foreignKey*: string
    ownerKey*: string

  SchemaMeta* = object
    tableName*: string
    fields*: seq[FieldMeta]
    primaryKeyField*: string
    associations*: seq[AssocMeta]

# --- Reflection helpers ---

proc schemaMeta*(T: typedesc): SchemaMeta {.compileTime.} =
  ## Връща метаданните за схемата.
  ## Всяка схема генерира своя собствена имплементация чрез макрото.
  SchemaMeta()

proc fieldIndex*(meta: SchemaMeta, fieldName: string): int =
  ## Връща индекса на поле по име. -1 ако не съществува.
  for i, f in meta.fields:
    if f.dbColumn == fieldName:
      return i
  -1

proc fieldByName*(meta: SchemaMeta, fieldName: string): FieldMeta =
  ## Връща FieldMeta по име на Nim поле.
  for f in meta.fields:
    if f.name == fieldName:
      return f
  raise newException(KeyError, "Field not found: " & fieldName)

# --- Row Loader ---

proc loadFromRow*[T](row: DbRow, meta: SchemaMeta): T =
  ## Преобразува DbRow в типизиран обект чрез SchemaMeta.
  ## Това е compile-time специализирана функция — всяка схема я override-ва.
  result = T()

# --- Помощни функции за макрото ---

proc extractTableName(body: NimNode): string =
  for child in body:
    if child.kind in {nnkCall, nnkCommand} and $child[0] == "table":
      return $child[1]
  result = ""

proc nimTypeToString(node: NimNode): string =
  ## Конвертира Nim type node в низ.
  case node.kind
  of nnkIdent:
    result = $node
  of nnkBracketExpr:
    let base = $node[0]
    if base == "Option":
      result = "Option[" & nimTypeToString(node[1]) & "]"
    elif base == "seq":
      result = "seq[" & nimTypeToString(node[1]) & "]"
    else:
      result = $node
  of nnkSym:
    result = $node
  else:
    result = $node

proc dbTypeForNim(nimType: string): string =
  case nimType
  of "string": "text"
  of "int": "integer"
  of "int64": "bigint"
  of "float", "float64": "double precision"
  of "bool": "boolean"
  of "DateTime": "timestamp with time zone"
  of "JsonNode": "jsonb"
  else:
    if nimType.startsWith("Option["):
      dbTypeForNim(nimType[7..^2])
    else:
      "text"  # fallback

proc toDbColumn(fieldName: string): string =
  ## Конвертира camelCase в snake_case за DB колона.
  result = ""
  for i, c in fieldName:
    if c >= 'A' and c <= 'Z':
      if i > 0:
        result.add('_')
      result.add(toLowerAscii(c))
    else:
      result.add(c)

# --- Главно макро: necto_schema ---

macro necto_schema*(name: untyped, body: untyped): untyped =
  ## Дефинира модел с полета и метаданни.
  ##
  ## Генерира:
  ##   1. type Name = ref object — типът
  ##   2. const NameSchema: SchemaMeta — метаданни за reflection
  ##   3. proc newName(): Name — конструктор
  ##   4. proc loadName(row: DbRow): Name — row loader
  ##   5. Changeset функции ако има `changeset` блокове

  let schemaName = $name
  let tableName = extractTableName(body)
  let finalTableName = if tableName.len > 0: tableName else: toLowerAscii(schemaName) & "s"

  # Колекции за генериране
  var fieldDefs: seq[NimNode] = @[]
  var fieldMetaNodes: seq[NimNode] = @[]
  var assocMetaNodes: seq[NimNode] = @[]
  var primaryKeyField = "id"
  var constructorAssignments: seq[NimNode] = @[]
  var rowLoadAssignments: seq[NimNode] = @[]
  var changesetFuncs: seq[NimNode] = @[]

  for child in body:
    if child.kind == nnkIdent:
      # Обработка на идентификатори без Command wrapper (напр. `timestamps`)
      let cmdName = $child
      if cmdName == "timestamps":
        for tsField in ["created_at", "updated_at"]:
          let fi = newIdentNode(tsField)
          fieldDefs.add(newIdentDefs(fi, newIdentNode("DateTime")))
          constructorAssignments.add(
            nnkAsgn.newTree(nnkDotExpr.newTree(newIdentNode("result"), fi), newCall(newIdentNode("now")))
          )
          let idx = fieldMetaNodes.len
          fieldMetaNodes.add(nnkObjConstr.newTree(
            newIdentNode("FieldMeta"),
            nnkExprColonExpr.newTree(newIdentNode("name"), newLit(tsField)),
            nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit(tsField)),
            nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit("DateTime")),
            nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit("timestamp with time zone")),
            nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(false)),
            nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(false)),
            nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(true)),
            nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(false)),
            nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit("")),
            nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
            nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(true))
          ))
          let tsId = fi
          rowLoadAssignments.add(quote do:
            result.`tsId` = loadValue(row[`idx`], DateTime)
          )

    elif child.kind in {nnkCall, nnkCommand}:
      # Команди с име и аргументи: table "x", field x: y, belongs_to x: Y
      let cmdName = $child[0]

      if cmdName == "table":
        discard  # вече обработено

      elif cmdName == "field":
        ## AST: Command(Ident "field", Ident "fieldName", StmtList(<type-expr>))
        ## type-expr може да е Ident "string" или PragmaExpr за полета с прагми
        let fieldName = $child[1]
        let typeBody = child[2]  # StmtList
        var fieldType: NimNode
        var isPrimaryKey = false
        var isAutoIncrement = false
        var isNullable = true
        var isUnique = false
        var defaultVal = ""

        if typeBody.len >= 1:
          let typeExpr = typeBody[0]
          if typeExpr.kind == nnkPragmaExpr:
            # field x: int64 {.primary_key.}
            fieldType = typeExpr[0]  # самият тип
            let pragmaNode = typeExpr[1]
            for p in pragmaNode:
              let pStr = $p
              case pStr
              of "primary_key": isPrimaryKey = true
              of "auto_increment": isAutoIncrement = true
              of "null_false", "not_null": isNullable = false
              of "unique": isUnique = true
              else: discard
          else:
            fieldType = typeExpr  # обикновен тип без прагми

        if isPrimaryKey:
          primaryKeyField = toDbColumn(fieldName)

        let nimTypeStr = nimTypeToString(fieldType)
        let dbTypeStr = dbTypeForNim(nimTypeStr)
        let dbCol = toDbColumn(fieldName)

        # Добавяне на полето в тип дефиницията
        fieldDefs.add(newIdentDefs(newIdentNode(fieldName), fieldType))

        # Конструктор инициализация
        let assignStmt = nnkAsgn.newTree(
          nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(fieldName)),
          newCall(newIdentNode("default"), fieldType)
        )
        constructorAssignments.add(assignStmt)

        # FieldMeta
        let rowIndex = fieldMetaNodes.len
        fieldMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("FieldMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(fieldName)),
          nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit(dbCol)),
          nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit(nimTypeStr)),
          nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit(dbTypeStr)),
          nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(isPrimaryKey)),
          nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(isAutoIncrement)),
          nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(isNullable)),
          nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(isUnique)),
          nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit(defaultVal)),
          nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(false))
        ))

        let fieldId = newIdentNode(fieldName)
        rowLoadAssignments.add(quote do:
          result.`fieldId` = loadValue(row[`rowIndex`], `fieldType`)
        )

      elif cmdName == "belongs_to":
        ## AST: Command(Ident "belongs_to", Ident "assocName", StmtList(Ident "TypeName"))
        let assocName = $child[1]
        var assocType = ""
        if child.len >= 3 and child[2].len >= 1:
          assocType = $child[2][0]

        let fkField = assocName & "_id"
        let fi = newIdentNode(fkField)
        fieldDefs.add(newIdentDefs(fi, newIdentNode("int64")))
        constructorAssignments.add(
          nnkAsgn.newTree(nnkDotExpr.newTree(newIdentNode("result"), fi), newLit(0'i64))
        )
        let idx = fieldMetaNodes.len
        fieldMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("FieldMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(fkField)),
          nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit(fkField)),
          nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit("int64")),
          nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit("bigint")),
          nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(true)),
          nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit("")),
          nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(false))
        ))
        let fkId = fi
        rowLoadAssignments.add(quote do:
          result.`fkId` = loadValue(row[`idx`], int64)
        )

        # AssocMeta
        assocMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("AssocMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(assocName)),
          nnkExprColonExpr.newTree(newIdentNode("kind"), newIdentNode("akBelongsTo")),
          nnkExprColonExpr.newTree(newIdentNode("targetSchema"), newLit(assocType)),
          nnkExprColonExpr.newTree(newIdentNode("foreignKey"), newLit(fkField)),
          nnkExprColonExpr.newTree(newIdentNode("ownerKey"), newLit("id"))
        ))

      elif cmdName == "has_many":
        ## AST: Command(Ident "has_many", Ident "assocName", StmtList(Ident "TargetType"))
        let assocName = $child[1]
        var targetType = ""
        if child.len >= 3 and child[2].len >= 1:
          targetType = $child[2][0]

        # Виртуално поле: comments: seq[TargetType]
        let seqType = newTree(nnkBracketExpr, newIdentNode("seq"), newIdentNode(targetType))
        fieldDefs.add(newIdentDefs(newIdentNode(assocName), seqType))
        constructorAssignments.add(
          nnkAsgn.newTree(
            nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(assocName)),
            newCall(newIdentNode("@"), newTree(nnkBracket))
          )
        )

        # AssocMeta
        assocMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("AssocMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(assocName)),
          nnkExprColonExpr.newTree(newIdentNode("kind"), newIdentNode("akHasMany")),
          nnkExprColonExpr.newTree(newIdentNode("targetSchema"), newLit(targetType)),
          nnkExprColonExpr.newTree(newIdentNode("foreignKey"),
            newLit(toLowerAscii(schemaName) & "_id")),
          nnkExprColonExpr.newTree(newIdentNode("ownerKey"), newLit("id"))
        ))

      elif cmdName == "has_one":
        let assocName = $child[1]
        var targetType = ""
        if child.len >= 3 and child[2].len >= 1:
          targetType = $child[2][0]

        # Виртуално поле: profile: TargetType
        fieldDefs.add(newIdentDefs(newIdentNode(assocName), newIdentNode(targetType)))
        constructorAssignments.add(
          nnkAsgn.newTree(
            nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(assocName)),
            newNilLit()
          )
        )

        assocMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("AssocMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(assocName)),
          nnkExprColonExpr.newTree(newIdentNode("kind"), newIdentNode("akHasOne")),
          nnkExprColonExpr.newTree(newIdentNode("targetSchema"), newLit(targetType)),
          nnkExprColonExpr.newTree(newIdentNode("foreignKey"),
            newLit(toLowerAscii(schemaName) & "_id")),
          nnkExprColonExpr.newTree(newIdentNode("ownerKey"), newLit("id"))
        ))

      elif cmdName == "changeset":
        ## Для по-късно — генерира changeset функция
        let changesetName = $child[1]
        let changesetBody = child[2]

        # Очаква се тялото да използва `this` и pipe оператор
        # this |> castFields(params, @[...]) |> validateRequired(@[...])
        # Генерираме:
        # proc name_changeset(params: Table[string,string]): Changeset[Name] =
        #   var this = newChangeset(newName(), params)
        #   this.action = "insert"
        #   body (където `this` е достъпен)

        let funcName = ident(toLowerAscii(schemaName) & "_" & changesetName)
        let tt = ident(schemaName)
        let changesetProc = quote do:
          proc `funcName`*(params: Table[string, string]): Changeset[`tt`] =
            var this = newChangeset(new`tt`(), params)
            this.action = "insert"
            `changesetBody`
        changesetFuncs.add(changesetProc)

  # --- Генериране на type дефиницията ---
  let typeName = newIdentNode(schemaName)
  let schemaMetaConst = newIdentNode(schemaName & "Schema")

  var recList = newTree(nnkRecList)
  for fd in fieldDefs:
    recList.add(fd)

  var typeDef = newTree(nnkTypeDef,
    newTree(nnkPostfix, newIdentNode("*"), typeName),
    newEmptyNode(),
    newTree(nnkRefTy,
      newTree(nnkObjectTy,
        newEmptyNode(),
        newEmptyNode(),
        recList
      )
    )
  )

  var typeSection = newTree(nnkTypeSection, typeDef)

  # --- Генериране на SchemaMeta константа ---
  var fieldSeq = newTree(nnkPrefix,
    newIdentNode("@"),
    newTree(nnkBracket)
  )
  for fm in fieldMetaNodes:
    fieldSeq[1].add(fm)

  var schemaMetaLet = newTree(nnkLetSection,
    newTree(nnkIdentDefs,
      newTree(nnkPostfix, newIdentNode("*"), schemaMetaConst),
      newEmptyNode(),
      newTree(nnkObjConstr,
        newIdentNode("SchemaMeta"),
        nnkExprColonExpr.newTree(newIdentNode("tableName"), newLit(finalTableName)),
        nnkExprColonExpr.newTree(newIdentNode("fields"), fieldSeq),
        nnkExprColonExpr.newTree(newIdentNode("primaryKeyField"), newLit(primaryKeyField)),
        nnkExprColonExpr.newTree(newIdentNode("associations"),
          newTree(nnkPrefix, newIdentNode("@"), newTree(nnkBracket))
        )
      )
    )
  )
  for am in assocMetaNodes:
    schemaMetaLet[0][2][^1][1][1].add(am)

  # --- Генериране на конструктор ---
  let newProcName = newIdentNode("new" & schemaName)
  let newProcBody = newStmtList()
  newProcBody.add(nnkAsgn.newTree(newIdentNode("result"), newCall(typeName)))
  for ca in constructorAssignments:
    newProcBody.add(ca)

  var newProc = newTree(nnkProcDef,
    newTree(nnkPostfix, newIdentNode("*"), newProcName),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams, typeName),
    newEmptyNode(),
    newEmptyNode(),
    newProcBody
  )

  # --- Генериране на row loader ---
  let loadProcName = newIdentNode("load" & schemaName)
  var loadProcBody = newStmtList()
  loadProcBody.add(nnkAsgn.newTree(newIdentNode("result"), newCall(newProcName)))
  for rl in rowLoadAssignments:
    loadProcBody.add(rl)

  var loadProc = newTree(nnkProcDef,
    newTree(nnkPostfix, newIdentNode("*"), loadProcName),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams,
      typeName,
      newTree(nnkIdentDefs, newIdentNode("row"), newIdentNode("DbRow"), newEmptyNode())
    ),
    newEmptyNode(),
    newEmptyNode(),
    loadProcBody
  )

  # --- Генериране на getFieldVal template ---
  var getFieldWhenBranches: seq[NimNode] = @[]
  for fd in fieldDefs:
    let fieldId = fd[0]
    let fieldNameStr = if fieldId.kind == nnkIdent: $fieldId else: $fieldId[0]
    let cond = nnkInfix.newTree(newIdentNode("=="), newIdentNode("fieldName"), newLit(fieldNameStr))
    let body = nnkDotExpr.newTree(newIdentNode("obj"), fieldId)
    getFieldWhenBranches.add(newTree(nnkElifBranch, cond, body))
  let getFieldWhenStmt = newTree(nnkWhenStmt, getFieldWhenBranches)

  var getFieldTemplate = newTree(nnkTemplateDef,
    newTree(nnkPostfix, newIdentNode("*"), newIdentNode("getFieldVal")),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams,
      newIdentNode("untyped"),
      newTree(nnkIdentDefs, newIdentNode("obj"), typeName, newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("fieldName"), newTree(nnkBracketExpr, newIdentNode("static"), newIdentNode("string")), newEmptyNode())
    ),
    newEmptyNode(),
    newEmptyNode(),
    getFieldWhenStmt
  )

  # --- Генериране на setFieldVal template ---
  var setFieldWhenBranches: seq[NimNode] = @[]
  for fd in fieldDefs:
    let fieldId = fd[0]
    let fieldNameStr = if fieldId.kind == nnkIdent: $fieldId else: $fieldId[0]
    let cond = nnkInfix.newTree(newIdentNode("=="), newIdentNode("fieldName"), newLit(fieldNameStr))
    let body = nnkAsgn.newTree(nnkDotExpr.newTree(newIdentNode("obj"), fieldId), newIdentNode("value"))
    setFieldWhenBranches.add(newTree(nnkElifBranch, cond, body))
  setFieldWhenBranches.add(newTree(nnkElse,
    newTree(nnkStaticStmt, newCall(newIdentNode("error"), newLit("Unknown field for set: " & schemaName & ".")))))

  let setFieldWhenStmt = newTree(nnkWhenStmt, setFieldWhenBranches)

  var setFieldTemplate = newTree(nnkTemplateDef,
    newTree(nnkPostfix, newIdentNode("*"), newIdentNode("setFieldVal")),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, newIdentNode("obj"), newTree(nnkVarTy, typeName), newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("fieldName"), newTree(nnkBracketExpr, newIdentNode("static"), newIdentNode("string")), newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("value"), newIdentNode("untyped"), newEmptyNode())
    ),
    newEmptyNode(),
    newEmptyNode(),
    setFieldWhenStmt
  )

  # --- Генериране на typedesc dispatch за schemaMeta и load ---
  let dispatchProcs = quote do:
    proc schemaMeta*(T: typedesc[`typeName`]): SchemaMeta =
      `schemaMetaConst`

    proc load*(row: DbRow, T: typedesc[`typeName`]): `typeName` =
      `loadProcName`(row)

  # --- Сглобяване ---
  result = newStmtList()
  result.add(typeSection)
  result.add(schemaMetaLet)
  result.add(newProc)
  result.add(loadProc)
  result.add(getFieldTemplate)
  result.add(setFieldTemplate)

  # --- Генериране на getFieldValRuntime proc (runtime string field access) ---
  var getFieldRuntimeCaseBranches: seq[NimNode] = @[]
  for fm in fieldMetaNodes:
    let fieldNameNode = fm[1][1]
    let fieldNameStr = $fieldNameNode
    let fieldId = newIdentNode(fieldNameStr)
    let ofBranch = newTree(nnkOfBranch, fieldNameNode,
      newCall(newIdentNode("$"), nnkDotExpr.newTree(newIdentNode("obj"), fieldId)))
    getFieldRuntimeCaseBranches.add(ofBranch)
  getFieldRuntimeCaseBranches.add(newTree(nnkElse, newLit("")))

  var getFieldRuntimeCaseStmt = newTree(nnkCaseStmt, newIdentNode("fieldName"))
  for b in getFieldRuntimeCaseBranches:
    getFieldRuntimeCaseStmt.add(b)

  var getFieldRuntimeProc = newTree(nnkProcDef,
    newTree(nnkPostfix, newIdentNode("*"), newIdentNode("getFieldValRuntime")),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams,
      newIdentNode("string"),
      newTree(nnkIdentDefs, newIdentNode("obj"), typeName, newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("fieldName"), newIdentNode("string"), newEmptyNode())
    ),
    newEmptyNode(),
    newEmptyNode(),
    getFieldRuntimeCaseStmt
  )
  result.add(getFieldRuntimeProc)

  # --- Генериране на preloadAssoc template ---
  var preloadWhenBranches: seq[NimNode] = @[]
  for am in assocMetaNodes:
    let assocNameLit = am[1][1]
    let kindIdent = am[2][1]
    let targetSchemaLit = am[3][1]
    let childType = newIdentNode($targetSchemaLit)
    let kindStr = $kindIdent

    var preloadCall: NimNode
    if kindStr == "akBelongsTo":
      preloadCall = quote do:
        discard preloadBelongsTo[`typeName`, `childType`](repo, records)
    elif kindStr == "akHasMany":
      preloadCall = quote do:
        discard preloadHasMany[`typeName`, `childType`](repo, records)
    elif kindStr == "akHasOne":
      preloadCall = quote do:
        discard preloadHasOne[`typeName`, `childType`](repo, records)
    else:
      continue

    let cond = nnkInfix.newTree(newIdentNode("=="), newIdentNode("assocName"), assocNameLit)
    preloadWhenBranches.add(newTree(nnkElifBranch, cond, preloadCall))

  if preloadWhenBranches.len > 0:
    preloadWhenBranches.add(newTree(nnkElse,
      newTree(nnkStaticStmt, newCall(newIdentNode("error"), newLit("Unknown association on " & schemaName)))))

    let preloadWhenStmt = newTree(nnkWhenStmt, preloadWhenBranches)

    var preloadTemplate = newTree(nnkTemplateDef,
      newTree(nnkPostfix, newIdentNode("*"), newIdentNode("preloadAssoc")),
      newEmptyNode(),
      newEmptyNode(),
      newTree(nnkFormalParams,
        newIdentNode("untyped"),
        newTree(nnkIdentDefs, newIdentNode("assocName"), newTree(nnkBracketExpr, newIdentNode("static"), newIdentNode("string")), newEmptyNode()),
        newTree(nnkIdentDefs, newIdentNode("repo"), newIdentNode("Repo"), newEmptyNode()),
        newTree(nnkIdentDefs, newIdentNode("records"), newTree(nnkBracketExpr, newIdentNode("seq"), typeName), newEmptyNode())
      ),
      newEmptyNode(),
      newEmptyNode(),
      preloadWhenStmt
    )
    result.add(preloadTemplate)

  result.add(dispatchProcs)
  for cf in changesetFuncs:
    result.add(cf)

  # Коментирайте за debug:
  # echo result.repr
