## Necto Schema
##
## Дефиниране на модели чрез `necto_schema` макрото.
## Генерира тип, метаданни и helper-и за reflection.
##
## Пример:
##   necto_schema User:
##     table "users"
##     field id: int64 {primary_key, auto_increment}
##     field name: string {null: false}
##     field email: string {null: false}
##     timestamps

import std/[macros, tables, strutils, typetraits, times]
import ./type_system

export type_system

# --- Schema Metadata ---

type
  FieldMeta* = object
    name*: string
    nimType*: string
    dbType*: string
    primaryKey*: bool
    autoIncrement*: bool
    nullable*: bool
    unique*: bool
    default*: string
    virtual*: bool

  SchemaMeta* = object
    tableName*: string
    fields*: seq[FieldMeta]

# --- Reflection helpers ---

proc schemaMeta*(T: typedesc): SchemaMeta =
  ## Връща метаданните за схемата. За сега placeholder.
  ## В бъдеще ще се генерира от макрото.
  SchemaMeta()

# --- Макро за дефиниране на Schema ---

macro necto_schema*(name: untyped, body: untyped): untyped =
  ## Дефинира модел с полета и метаданни.
  result = newStmtList()

  var tableName = toLowerAscii($name) & "s"
  var fieldDefs: seq[NimNode] = @[]

  for child in body:
    if child.kind == nnkCall and $child[0] == "table":
      tableName = $child[1]
    elif child.kind == nnkCall and $child[0] == "field":
      let decl = child[1]
      var fieldName: string
      var fieldType: NimNode
      var pragmas: seq[NimNode] = @[]

      if decl.kind == nnkExprColonExpr:
        fieldName = $decl[0]
        fieldType = decl[1]
      elif decl.kind == nnkPragmaExpr:
        let inner = decl[0]
        fieldName = $inner[0]
        fieldType = inner[1]
        for p in decl[1]:
          pragmas.add(p)

      var identNode = ident(fieldName)
      var identDef = newIdentDefs(identNode, fieldType)
      if pragmas.len > 0:
        var pragmaNode = newTree(nnkPragma, pragmas)
        identDef = newTree(nnkPragmaExpr, identDef, pragmaNode)
      fieldDefs.add(identDef)

    elif child.kind == nnkCall and $child[0] == "timestamps":
      fieldDefs.add(newIdentDefs(ident("created_at"), ident("DateTime")))
      fieldDefs.add(newIdentDefs(ident("updated_at"), ident("DateTime")))

  # Създаваме типа ръчно чрез AST
  let typeName = name
  var recList = newTree(nnkRecList)
  for fd in fieldDefs:
    recList.add(fd)

  var typeDef = newTree(nnkTypeDef,
    newTree(nnkPostfix, ident("*"), typeName),
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
  result.add(typeSection)
