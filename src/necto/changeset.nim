## Necto Changeset
##
## Проследява, cast-ва и валидира промени преди запис в БД.
##
## Пример:
##   let cs = User.changeset(%{"name": "Ivan", "email": "ivan@test.com"})
##             .cast(@["name", "email"])
##             .validate_required(@["name", "email"])
##             .validate_format("email", re".+@.+")

import std/[tables, strutils, re, options, macros, sequtils]
import ./schema
import ./type_system
import ./errors

export schema, type_system, errors

type
  Validation* = object
    field*: string
    message*: string

  ConstraintKind* = enum
    ckUnique, ckForeignKey, ckExclusion

  ConstraintMeta* = object
    kind*: ConstraintKind
    field*: string
    message*: string

  Changeset*[T] = object
    ## Структура, която държи състоянието на една промяна.
    data*: T
    params*: Table[string, string]
    changes*: Table[string, string]
    errors*: Table[string, seq[string]]
    valid*: bool
    action*: string   # "insert", "update", "delete"
    constraints*: Table[string, seq[ConstraintMeta]]

# --- Конструктор ---

proc newChangeset*[T](data: T, params: Table[string, string] = initTable[string, string]()): Changeset[T] =
  Changeset[T](
    data: data,
    params: params,
    changes: initTable[string, string](),
    errors: initTable[string, seq[string]](),
    valid: true,
    action: "",
    constraints: initTable[string, seq[ConstraintMeta]]()
  )

# --- Cast ---

template castFields*[T](cs: Changeset[T], permitted: openArray[string]): Changeset[T] =
  ## Филтрира и конвертира позволените полета от params.
  ## Използва SchemaMeta за правилно type casting.
  mixin schemaMeta
  block:
    let meta = schemaMeta(T)
    var result = cs
    for field in permitted:
      if result.params.hasKey(field):
        var fmeta: FieldMeta
        var found = false
        for f in meta.fields:
          if f.name == field:
            fmeta = f
            found = true
            break
        if found:
          let rawVal = result.params[field]
          try:
            result.changes[field] = castToDb(rawVal, fmeta.nimType)
          except ValueError:
            result.addError(field, "is invalid")
        else:
          result.changes[field] = result.params[field]
    result

# --- Валидации ---

proc addError*[T](cs: var Changeset[T], field, message: string) =
  if not cs.errors.hasKey(field):
    cs.errors[field] = @[]
  cs.errors[field].add(message)
  cs.valid = false

proc validateRequired*[T](cs: Changeset[T], fields: openArray[string]): Changeset[T] =
  result = cs
  for field in fields:
    if not result.changes.hasKey(field) or result.changes[field].strip().len == 0:
      result.addError(field, "can't be blank")

proc validateFormat*[T](cs: Changeset[T], field: string, pattern: Regex): Changeset[T] =
  result = cs
  if result.changes.hasKey(field):
    if not result.changes[field].match(pattern):
      result.addError(field, "has invalid format")

proc validateInclusion*[T](cs: Changeset[T], field: string, range: Slice[int]): Changeset[T] =
  result = cs
  if result.changes.hasKey(field):
    try:
      let val = parseInt(result.changes[field])
      if val < range.a or val > range.b:
        result.addError(field, "is not included in the range")
    except ValueError:
      result.addError(field, "is not a number")

proc validateLength*[T](cs: Changeset[T], field: string; min, max: int): Changeset[T] =
  result = cs
  if result.changes.hasKey(field):
    let len = result.changes[field].len
    if min > 0 and len < min:
      result.addError(field, "is too short (minimum is " & $min & " characters)")
    if max > 0 and len > max:
      result.addError(field, "is too long (maximum is " & $max & " characters)")

proc validateNumber*[T](cs: Changeset[T], field: string; greaterThan, lessThan: int): Changeset[T] =
  result = cs
  if result.changes.hasKey(field):
    try:
      let val = parseInt(result.changes[field])
      if greaterThan != low(int) and val <= greaterThan:
        result.addError(field, "must be greater than " & $greaterThan)
      if lessThan != high(int) and val >= lessThan:
        result.addError(field, "must be less than " & $lessThan)
    except ValueError:
      result.addError(field, "is not a number")

# --- Constraints ---

proc uniqueConstraint*[T](cs: Changeset[T], field: string, message: string = "has already been taken"): Changeset[T] =
  ## Маркира полето като subject към unique constraint.
  ## Проверката се случва в Repo при insert/update, като лови DB грешка.
  result = cs
  if not result.constraints.hasKey(field):
    result.constraints[field] = @[]
  result.constraints[field].add(ConstraintMeta(
    kind: ckUnique,
    field: field,
    message: message
  ))

proc foreignKeyConstraint*[T](cs: Changeset[T], field: string, message: string = "does not exist"): Changeset[T] =
  ## Маркира полето като subject към foreign key constraint.
  result = cs
  if not result.constraints.hasKey(field):
    result.constraints[field] = @[]
  result.constraints[field].add(ConstraintMeta(
    kind: ckForeignKey,
    field: field,
    message: message
  ))

proc checkConstraint*[T](cs: Changeset[T], field: string, message: string = "is invalid"): Changeset[T] =
  ## Маркира полето за check constraint.
  result = cs
  if not result.constraints.hasKey(field):
    result.constraints[field] = @[]
  result.constraints[field].add(ConstraintMeta(
    kind: ckExclusion,
    field: field,
    message: message
  ))

# --- Helpers ---

proc isValid*[T](cs: Changeset[T]): bool = cs.valid
proc isInvalid*[T](cs: Changeset[T]): bool = not cs.valid

proc getChange*[T](cs: Changeset[T], field: string): Option[string] =
  if cs.changes.hasKey(field):
    some(cs.changes[field])
  else:
    none(string)

proc getError*[T](cs: Changeset[T], field: string): seq[string] =
  if cs.errors.hasKey(field):
    cs.errors[field]
  else:
    @[]

# --- Change Management ---

proc putChange*[T](cs: Changeset[T], field: string, value: string): Changeset[T] =
  ## Директно задава стойност в changeset (без да идва от params).
  result = cs
  result.changes[field] = value

proc forceChange*[T](cs: Changeset[T], field: string, value: string): Changeset[T] =
  ## Принудително задава стойност, дори ако не се различава от оригиналната.
  result = cs
  result.changes[field] = value

proc deleteChange*[T](cs: Changeset[T], field: string): Changeset[T] =
  ## Премахва поле от changes.
  result = cs
  result.changes.del(field)

proc hasChange*[T](cs: Changeset[T], field: string): bool =
  cs.changes.hasKey(field)

proc changedFields*[T](cs: Changeset[T]): seq[string] =
  toSeq(cs.changes.keys)

iterator changes*[T](cs: Changeset[T]): (string, string) =
  for key, val in cs.changes.pairs:
    yield (key, val)

# --- Apply Changes ---

proc applyChanges*[T](cs: Changeset[T]): T =
  ## Прилага промените към обекта без запис в БД.
  ## Връща нов обект с нанесените стойности от changes.
  result = cs.data
  for field, value in cs.changes.pairs():
    when compiles(setFieldValRuntime(result, field, value)):
      setFieldValRuntime(result, field, value)
    else:
      discard

# --- Constraint helpers ---

proc getConstraints*[T](cs: Changeset[T], field: string): seq[ConstraintMeta] =
  if cs.constraints.hasKey(field):
    cs.constraints[field]
  else:
    @[]

proc hasConstraints*[T](cs: Changeset[T]): bool =
  cs.constraints.len > 0

proc allConstraints*[T](cs: Changeset[T]): seq[(string, ConstraintMeta)] =
  for field, metas in cs.constraints.pairs():
    for m in metas:
      result.add((field, m))

# --- Ecto-style Constraint Helpers ---

proc noAssocConstraint*[T](cs: Changeset[T], field: string, message: string = "does not exist"): Changeset[T] =
  ## Проверява дали свързания обект съществува.
  result = cs
  if not result.constraints.hasKey(field):
    result.constraints[field] = @[]
  result.constraints[field].add(ConstraintMeta(
    kind: ckForeignKey,
    field: field,
    message: message
  ))
