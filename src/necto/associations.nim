## Necto Associations
##
## Дефиниране на релации между модели.
##
## Пример:
##   necto_schema Post:
##     belongs_to author: User
##     has_many comments: Comment
##     has_one draft: Draft
##
## Зареждането е винаги explicit чрез preload:
##   Query.from(Post).preload(:author)

import std/[macros, tables, strutils, sequtils, options]
import ./schema
import ./query
import ./errors

export schema, query, errors

type
  AssocType* = enum
    BelongsTo, HasMany, HasOne, ManyToMany

  Association* = object
    name*: string
    assocType*: AssocType
    targetSchema*: string
    foreignKey*: string
    ownerKey*: string

# --- Preload логика (placeholder) ---

proc preloadAssoc*[Parent, Child](parent: Parent, assocName: string, queryObj: Query[Child]): Parent =
  ## Зарежда асоциация върху един обект.
  ## TODO: изпълни заявка, сетни релацията.
  parent

proc preloadAssoc*[Parent, Child](parents: seq[Parent], assocName: string, queryObj: Query[Child]): seq[Parent] =
  ## Зарежда асоциация върху колекция (batch load).
  ## TODO: N+1 avoidance чрез IN clause.
  parents

# --- Helper макроси за декларация в schema ---
##
## Тези ще бъдат интегрирани в necto_schema макрото.

proc belongsToMacro*(target: string, foreignKey: string = ""): Association =
  let fk = if foreignKey.len > 0: foreignKey else: toLowerAscii(target) & "_id"
  Association(name: toLowerAscii(target), assocType: BelongsTo, targetSchema: target, foreignKey: fk, ownerKey: "id")

proc hasManyMacro*(target: string, foreignKey: string = ""): Association =
  let fk = if foreignKey.len > 0: foreignKey else: ""
  Association(name: toLowerAscii(target) & "s", assocType: HasMany, targetSchema: target, foreignKey: fk, ownerKey: "id")

proc hasOneMacro*(target: string, foreignKey: string = ""): Association =
  let fk = if foreignKey.len > 0: foreignKey else: ""
  Association(name: toLowerAscii(target), assocType: HasOne, targetSchema: target, foreignKey: fk, ownerKey: "id")
