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

import std/[macros, tables, strutils, times, json]
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
    akBelongsTo, akHasMany, akHasOne, akManyToMany

  AssocMeta* = object
    name*: string
    kind*: AssocKind
    targetSchema*: string
    foreignKey*: string
    ownerKey*: string
    joinTable*: string  ## За many_to_many — името на join таблицата

  SchemaMeta* = object
    tableName*: string
    fields*: seq[FieldMeta]
    primaryKeyField*: string
    associations*: seq[AssocMeta]
    softDeletes*: bool  ## Ако true, schema-та поддържа soft deletes

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
    elif base == "JsonB":
      result = "JsonB[" & nimTypeToString(node[1]) & "]"
    else:
      result = base & "[" & nimTypeToString(node[1]) & "]"
  of nnkSym:
    result = $node
  else:
    result = $node

proc stringToNimType(typeStr: string): NimNode =
  ## Конвертира низ обратно в Nim type node.
  if typeStr.startsWith("Option["):
    let inner = stringToNimType(typeStr[7..^2])
    result = nnkBracketExpr.newTree(newIdentNode("Option"), inner)
  elif typeStr.startsWith("seq["):
    let inner = stringToNimType(typeStr[4..^2])
    result = nnkBracketExpr.newTree(newIdentNode("seq"), inner)
  elif typeStr.startsWith("JsonB["):
    let inner = stringToNimType(typeStr[6..^2])
    result = nnkBracketExpr.newTree(newIdentNode("JsonB"), inner)
  else:
    result = newIdentNode(typeStr)

proc dbTypeForNim*(nimType: string): string {.compileTime.} =
  ## Връща PostgreSQL типа за даден Nim тип (като низ).
  ## За built-in типове ползва `dbType()` overload-ите от type_system.
  ## За custom типове проверява `nectoTypeRegistry` (registerNectoType).
  ## За PostgreSQL-специфични типове (PgPoint, etc.) ползва хардкоднати стойности.
  case nimType
  of "string": dbType(string)
  of "int", "int32": dbType(int)
  of "int16": dbType(int16)
  of "int64": dbType(int64)
  of "float", "float64": dbType(float)
  of "bool": dbType(bool)
  of "DateTime": dbType(DateTime)
  of "Date": dbType(Date)
  of "TimeOfDay": dbType(TimeOfDay)
  of "JsonNode": dbType(JsonNode)
  of "Uuid": dbType(Uuid)
  of "Decimal": dbType(Decimal)
  of "seq[byte]": dbType(seq[byte])
  of "PgPoint": "point"
  of "PgInet": "inet"
  of "PgCidr": "cidr"
  of "PgMacAddr": "macaddr"
  of "PgTsVector": "tsvector"
  of "PgTsQuery": "tsquery"
  of "Money": "bigint"
  else:
    # Провери custom type registry първо
    let custom = resolveCustomDbType(nimType)
    if custom.len > 0:
      return custom
    # Generics: JsonB[T], Option[T], seq[T]
    if nimType.startsWith("JsonB["):
      "jsonb"
    elif nimType.startsWith("Option["):
      dbTypeForNim(nimType[7..^2])
    elif nimType.startsWith("seq["):
      let inner = nimType[4..^2]
      dbTypeForNim(inner) & "[]"
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
  var hasVerify = false
  var hasSoftDeletes = false
  var verifyFields: seq[(string, string, string, string, bool, bool, bool)] = @[]

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

      elif cmdName == "soft_deletes":
        hasSoftDeletes = true
        let fi = newIdentNode("deleted_at")
        let optDt = newTree(nnkBracketExpr, newIdentNode("Option"), newIdentNode("DateTime"))
        fieldDefs.add(newIdentDefs(fi, optDt))
        constructorAssignments.add(
          nnkAsgn.newTree(nnkDotExpr.newTree(newIdentNode("result"), fi), newCall(newIdentNode("none"), newIdentNode("DateTime")))
        )
        let idx = fieldMetaNodes.len
        fieldMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("FieldMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit("deleted_at")),
          nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit("deleted_at")),
          nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit("Option[DateTime]")),
          nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit("timestamp with time zone")),
          nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(true)),
          nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit("")),
          nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(false))
        ))
        rowLoadAssignments.add(quote do:
          result.deleted_at = loadValue(row[`idx`], Option[DateTime])
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

        # Запомни за verify
        verifyFields.add((fieldName, dbCol, nimTypeStr, dbTypeStr, isPrimaryKey, isNullable, isUnique))

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

        # Internal pointer field for preloaded association object
        let ptrFieldName = assocName & "Cache"
        let ptrField = newIdentNode(ptrFieldName)
        fieldDefs.add(newIdentDefs(ptrField, newIdentNode("pointer")))
        constructorAssignments.add(
          nnkAsgn.newTree(nnkDotExpr.newTree(newIdentNode("result"), ptrField), newNilLit())
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

      elif cmdName == "many_to_many":
        ## AST: Command(Ident "many_to_many", Ident "assocName",
        ##               StmtList(Command(Ident "TargetType", Command(Ident "through", StrLit "joinTable"))))
        let assocName = $child[1]
        var targetType = ""
        var joinTable = ""
        if child.len >= 3 and child[2].kind == nnkStmtList and child[2].len >= 1:
          let typeNode = child[2][0]
          if typeNode.kind == nnkCommand and typeNode.len >= 2:
            targetType = $typeNode[0]
            let throughCmd = typeNode[1]
            if throughCmd.kind == nnkCommand and throughCmd.len >= 2 and $throughCmd[0] == "through":
              joinTable = $throughCmd[1]
            else:
              joinTable = toLowerAscii(schemaName) & "_" & toLowerAscii(targetType)
          elif typeNode.kind == nnkIdent:
            targetType = $typeNode
            joinTable = toLowerAscii(schemaName) & "_" & toLowerAscii(targetType)

        # Виртуално поле: roles: seq[TargetType]
        let seqType = newTree(nnkBracketExpr, newIdentNode("seq"), newIdentNode(targetType))
        fieldDefs.add(newIdentDefs(newIdentNode(assocName), seqType))
        constructorAssignments.add(
          nnkAsgn.newTree(
            nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(assocName)),
            newCall(newIdentNode("@"), newTree(nnkBracket))
          )
        )

        assocMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("AssocMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(assocName)),
          nnkExprColonExpr.newTree(newIdentNode("kind"), newIdentNode("akManyToMany")),
          nnkExprColonExpr.newTree(newIdentNode("targetSchema"), newLit(targetType)),
          nnkExprColonExpr.newTree(newIdentNode("foreignKey"), newLit("")),
          nnkExprColonExpr.newTree(newIdentNode("ownerKey"), newLit("id")),
          nnkExprColonExpr.newTree(newIdentNode("joinTable"), newLit(joinTable))
        ))

      elif cmdName == "embeds_one":
        ## AST: Command(Ident "embeds_one", Ident "fieldName", StmtList(Ident "TypeName"))
        let fieldName = $child[1]
        var innerType = ""
        if child.len >= 3 and child[2].len >= 1:
          innerType = $child[2][0]
        let jsonbType = newTree(nnkBracketExpr, newIdentNode("JsonB"), newIdentNode(innerType))
        fieldDefs.add(newIdentDefs(newIdentNode(fieldName), jsonbType))
        constructorAssignments.add(
          nnkAsgn.newTree(
            nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(fieldName)),
            newCall(jsonbType)
          )
        )
        let idx = fieldMetaNodes.len
        fieldMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("FieldMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(fieldName)),
          nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit(fieldName)),
          nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit("JsonB[" & innerType & "]")),
          nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit("jsonb")),
          nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(true)),
          nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit(""))
        ))
        let fieldNameIdent = newIdentNode(fieldName)
        let innerTypeIdent = newIdentNode(innerType)
        rowLoadAssignments.add(quote do:
          result.`fieldNameIdent` = loadValue(row[`idx`], JsonB[`innerTypeIdent`])
        )

      elif cmdName == "embeds_many":
        ## AST: Command(Ident "embeds_many", Ident "fieldName", StmtList(Ident "TypeName"))
        let fieldName = $child[1]
        var innerType = ""
        if child.len >= 3 and child[2].len >= 1:
          innerType = $child[2][0]
        let seqJsonbType = newTree(nnkBracketExpr, newIdentNode("JsonB"),
          newTree(nnkBracketExpr, newIdentNode("seq"), newIdentNode(innerType)))
        fieldDefs.add(newIdentDefs(newIdentNode(fieldName), seqJsonbType))
        constructorAssignments.add(
          nnkAsgn.newTree(
            nnkDotExpr.newTree(newIdentNode("result"), newIdentNode(fieldName)),
            newCall(seqJsonbType)
          )
        )
        let idx = fieldMetaNodes.len
        fieldMetaNodes.add(nnkObjConstr.newTree(
          newIdentNode("FieldMeta"),
          nnkExprColonExpr.newTree(newIdentNode("name"), newLit(fieldName)),
          nnkExprColonExpr.newTree(newIdentNode("dbColumn"), newLit(fieldName)),
          nnkExprColonExpr.newTree(newIdentNode("nimType"), newLit("JsonB[seq[" & innerType & "]]"))
          ,
          nnkExprColonExpr.newTree(newIdentNode("dbType"), newLit("jsonb")),
          nnkExprColonExpr.newTree(newIdentNode("primaryKey"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("autoIncrement"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("nullable"), newLit(true)),
          nnkExprColonExpr.newTree(newIdentNode("unique"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("virtual"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("isTimestamp"), newLit(false)),
          nnkExprColonExpr.newTree(newIdentNode("defaultValue"), newLit(""))
        ))
        let fieldNameIdent2 = newIdentNode(fieldName)
        let innerTypeIdent2 = newIdentNode(innerType)
        rowLoadAssignments.add(quote do:
          result.`fieldNameIdent2` = loadValue(row[`idx`], JsonB[seq[`innerTypeIdent2`]])
        )

      elif cmdName == "verify":
        hasVerify = true

      elif cmdName == "changeset":
        ## За по-късно — генерира changeset функция
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

  # --- Internal preload tracking field ---
  let preloadedType = newTree(nnkBracketExpr, newIdentNode("seq"), newIdentNode("string"))
  fieldDefs.add(newIdentDefs(newIdentNode("preloaded"), preloadedType))
  constructorAssignments.add(
    nnkAsgn.newTree(
      nnkDotExpr.newTree(newIdentNode("result"), newIdentNode("preloaded")),
      newCall(newIdentNode("@"), newTree(nnkBracket))
    )
  )

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
        ),
        nnkExprColonExpr.newTree(newIdentNode("softDeletes"), newLit(hasSoftDeletes))
      )
    )
  )
  for am in assocMetaNodes:
    schemaMetaLet[0][2][4][1][1].add(am)

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

  # --- Генериране на setFieldValRuntime proc ---
  var setFieldRuntimeCaseBranches: seq[NimNode] = @[]
  for fm in fieldMetaNodes:
    let fieldNameNode = fm[1][1]
    let fieldNameStr = $fieldNameNode
    let nimTypeNode = fm[3][1]
    let nimTypeStr = $nimTypeNode
    let fieldId = newIdentNode(fieldNameStr)
    let typeNode = stringToNimType(nimTypeStr)
    let assignBody = nnkAsgn.newTree(
      nnkDotExpr.newTree(newIdentNode("obj"), fieldId),
      newCall(newIdentNode("loadValue"), newIdentNode("value"), typeNode)
    )
    let ofBranch = newTree(nnkOfBranch, fieldNameNode, assignBody)
    setFieldRuntimeCaseBranches.add(ofBranch)
  setFieldRuntimeCaseBranches.add(newTree(nnkElse, newEmptyNode()))

  var setFieldRuntimeCaseStmt = newTree(nnkCaseStmt, newIdentNode("fieldName"))
  for b in setFieldRuntimeCaseBranches:
    setFieldRuntimeCaseStmt.add(b)

  var setFieldRuntimeProc = newTree(nnkProcDef,
    newTree(nnkPostfix, newIdentNode("*"), newIdentNode("setFieldValRuntime")),
    newEmptyNode(),
    newEmptyNode(),
    newTree(nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, newIdentNode("obj"), newTree(nnkVarTy, typeName), newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("fieldName"), newIdentNode("string"), newEmptyNode()),
      newTree(nnkIdentDefs, newIdentNode("value"), newIdentNode("string"), newEmptyNode())
    ),
    newEmptyNode(),
    newEmptyNode(),
    setFieldRuntimeCaseStmt
  )
  result.add(setFieldRuntimeProc)

  # --- Генериране на preloadAssoc template ---
  var preloadWhenBranches: seq[NimNode] = @[]
  var accessorTemplates: seq[NimNode] = @[]
  for am in assocMetaNodes:
    let assocNameLit = am[1][1]
    let kindIdent = am[2][1]
    let targetSchemaLit = am[3][1]
    let childType = newIdentNode($targetSchemaLit)
    let kindStr = $kindIdent
    let assocNameStr = $assocNameLit

    var preloadCall: NimNode
    if kindStr == "akBelongsTo":
      let fkField = am[4][1]
      let fkFieldNode = newIdentNode($fkField)
      let ptrFieldName = assocNameStr & "Cache"
      let ptrFieldNode = newIdentNode(ptrFieldName)
      preloadCall = quote do:
        var childMap: Table[int64, `childType`] = initTable[int64, `childType`]()
        if records.len == 0 or `assocNameLit` notin records[0].preloaded:
          childMap = preloadBelongsTo[`typeName`, `childType`](repo, records)
          for p in records:
            if childMap.hasKey(p.`fkFieldNode`):
              p.`ptrFieldNode` = cast[pointer](childMap[p.`fkFieldNode`])
            else:
              p.`ptrFieldNode` = nil
          for p in records:
            p.preloaded.add(`assocNameLit`)
        childMap
      let accessorIdent = newIdentNode($assocNameLit)
      var accessorTemplate = newTree(nnkTemplateDef,
        newTree(nnkPostfix, newIdentNode("*"), accessorIdent),
        newEmptyNode(),
        newEmptyNode(),
        newTree(nnkFormalParams,
          newIdentNode("untyped"),
          newTree(nnkIdentDefs, newIdentNode("p"), typeName, newEmptyNode())
        ),
        newEmptyNode(),
        newEmptyNode(),
        newStmtList(
          newTree(nnkCast, childType, nnkDotExpr.newTree(newIdentNode("p"), ptrFieldNode))
        )
      )
      accessorTemplates.add(accessorTemplate)
    elif kindStr == "akHasMany":
      let ownerKeyNode = newIdentNode("id")
      let assocFieldNode = newIdentNode(assocNameStr)
      preloadCall = quote do:
        var childGroups: Table[int64, seq[`childType`]] = initTable[int64, seq[`childType`]]()
        if records.len == 0 or `assocNameLit` notin records[0].preloaded:
          childGroups = preloadHasMany[`typeName`, `childType`](repo, records)
          for r in records:
            if childGroups.hasKey(r.`ownerKeyNode`):
              r.`assocFieldNode` = childGroups[r.`ownerKeyNode`]
            else:
              r.`assocFieldNode` = @[]
          for r in records:
            r.preloaded.add(`assocNameLit`)
        childGroups
    elif kindStr == "akHasOne":
      let ownerKeyNode = newIdentNode("id")
      let assocFieldNode = newIdentNode(assocNameStr)
      preloadCall = quote do:
        var childMap: Table[int64, `childType`] = initTable[int64, `childType`]()
        if records.len == 0 or `assocNameLit` notin records[0].preloaded:
          childMap = preloadHasOne[`typeName`, `childType`](repo, records)
          for r in records:
            if childMap.hasKey(r.`ownerKeyNode`):
              r.`assocFieldNode` = childMap[r.`ownerKeyNode`]
            else:
              r.`assocFieldNode` = nil
          for r in records:
            r.preloaded.add(`assocNameLit`)
        childMap
    elif kindStr == "akManyToMany":
      let ownerKeyNode = newIdentNode("id")
      let assocFieldNode = newIdentNode(assocNameStr)
      let joinTableLit = am[6][1]  ## joinTable string literal
      preloadCall = quote do:
        var childGroups: Table[int64, seq[`childType`]] = initTable[int64, seq[`childType`]]()
        if records.len == 0 or `assocNameLit` notin records[0].preloaded:
          childGroups = preloadManyToMany[`typeName`, `childType`](repo, records, `joinTableLit`)
          for r in records:
            if childGroups.hasKey(r.`ownerKeyNode`):
              r.`assocFieldNode` = childGroups[r.`ownerKeyNode`]
            else:
              r.`assocFieldNode` = @[]
          for r in records:
            r.preloaded.add(`assocNameLit`)
        childGroups
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

    # --- Генериране на autoPreloadAssocs template ---
    var autoPreloadStmts = newStmtList()
    for am in assocMetaNodes:
      let assocNameLit = am[1][1]
      let ifBranch = newTree(nnkIfStmt,
        newTree(nnkElifBranch,
          nnkInfix.newTree(newIdentNode("in"), assocNameLit, newIdentNode("names")),
          newStmtList(
            newTree(nnkDiscardStmt,
              newCall(newIdentNode("preloadAssoc"), assocNameLit, newIdentNode("repo"), newIdentNode("records"))
            )
          )
        )
      )
      autoPreloadStmts.add(ifBranch)

    var autoPreloadTemplate = newTree(nnkTemplateDef,
      newTree(nnkPostfix, newIdentNode("*"), newIdentNode("autoPreloadAssocs")),
      newEmptyNode(),
      newEmptyNode(),
      newTree(nnkFormalParams,
        newIdentNode("untyped"),
        newTree(nnkIdentDefs, newIdentNode("repo"), newIdentNode("Repo"), newEmptyNode()),
        newTree(nnkIdentDefs, newIdentNode("records"), newTree(nnkVarTy, newTree(nnkBracketExpr, newIdentNode("seq"), typeName)), newEmptyNode()),
        newTree(nnkIdentDefs, newIdentNode("names"), newTree(nnkBracketExpr, newIdentNode("seq"), newIdentNode("string")), newEmptyNode())
      ),
      newEmptyNode(),
      newEmptyNode(),
      autoPreloadStmts
    )
    result.add(autoPreloadTemplate)

  for at in accessorTemplates:
    result.add(at)

  result.add(dispatchProcs)
  for cf in changesetFuncs:
    result.add(cf)

  # --- Генериране на compile-time schema verification блок ---
  if hasVerify:
    var fieldInfoNodes = newTree(nnkBracket)
    for (nimName, dbCol, nimType, dbType, isPk, isNullable, isUnique) in verifyFields:
      fieldInfoNodes.add(quote do:
        SchemaFieldInfo(
          nimName: `nimName`,
          dbColumn: `dbCol`,
          nimType: `nimType`,
          dbType: `dbType`,
          isPrimaryKey: `isPk`,
          isNullable: `isNullable`,
          isUnique: `isUnique`
        )
      )

    let verifyProcName = newIdentNode("verify" & schemaName & "Schema")
    let verifyBlock = quote do:
      when defined(nectoVerify):
        import necto/schema_verifier

        proc `verifyProcName`() {.used.} =
          let cfg = getDbConfig()
          let fields = `fieldInfoNodes`
          let r = verifySchema(cfg.host, cfg.port, cfg.user, cfg.password,
                               cfg.database, `finalTableName`, fields)
          if r.errors.len > 0 or r.warnings.len > 0:
            echo formatResult(r)
          if r.errors.len > 0:
            quit(1)

        `verifyProcName`()

    result.add(verifyBlock)

  # Коментирайте за debug:
  # echo result.repr
