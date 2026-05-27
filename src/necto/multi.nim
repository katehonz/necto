## NectoMulti — Композируеми транзакции
##
## Вдъхновен от Ecto.Multi. Позволява именуван pipeline от операции
## с dependency tracking и atomic rollback.
##
## Пример:
##   let multi = newMulti()
##     .insert("user", userCs)
##     .insert("profile", profileCs, dependsOn = @["user"])
##     .update("account", accountCs)
##
##   repo.transactionMulti(multi)
##   # Всичко или нищо — ако която и да е стъпка fail-не,
##   # цялата транзакция се rollback-ва.

import std/[tables, sets, strutils]
import ./repo, ./changeset, ./errors, ./schema, ./query

export repo, changeset, errors, schema, query

type
  MultiContext* = Table[string, pointer]
    ## Контекст с резултатите от всяка стъпка. Ключът е името на стъпката.
    ## Стойностите са cast-нати указатели към schema обекти.

  MultiStepFn* = proc (repo: Repo, ctx: MultiContext): (pointer, string) {.closure.}
    ## Функция която изпълнява една стъпка. Връща (резултат, грешка).

  MultiStep* = object
    name*: string
    fn*: MultiStepFn
    dependsOn*: seq[string]

  Multi* = object
    steps*: seq[MultiStep]

proc newMulti*(): Multi =
  ## Създава ново празно Multi.
  Multi(steps: @[])

proc validateDependencies*(multi: Multi) =
  ## Проверява дали всички dependencies съществуват и имената са уникални.
  ## Хвърля ValueError при проблем.
  var seen = initHashSet[string]()
  for step in multi.steps:
    if step.name.len == 0:
      raise newException(ValueError, "Multi step name cannot be empty")
    if step.name in seen:
      raise newException(ValueError, "Duplicate multi step name: " & step.name)
    for dep in step.dependsOn:
      if dep notin seen:
        raise newException(ValueError, "Step '" & step.name & "' depends on '" & dep & "' which was not found")
    seen.incl(step.name)

proc insert*[T](multi: Multi, name: string, cs: Changeset[T]; dependsOn: seq[string] = @[]): Multi =
  ## Добавя INSERT стъпка към Multi.
  result = multi
  result.steps.add(MultiStep(
    name: name,
    dependsOn: dependsOn,
    fn: proc (repo: Repo, ctx: MultiContext): (pointer, string) =
      try:
        let inserted = repo.insert(cs)
        (cast[pointer](inserted), "")
      except CatchableError as e:
        (nil, e.msg)
  ))

proc update*[T](multi: Multi, name: string, cs: Changeset[T]; dependsOn: seq[string] = @[]): Multi =
  ## Добавя UPDATE стъпка към Multi.
  result = multi
  result.steps.add(MultiStep(
    name: name,
    dependsOn: dependsOn,
    fn: proc (repo: Repo, ctx: MultiContext): (pointer, string) =
      try:
        let updated = repo.update(cs)
        (cast[pointer](updated), "")
      except CatchableError as e:
        (nil, e.msg)
  ))

proc delete*[T](multi: Multi, name: string, cs: Changeset[T]; dependsOn: seq[string] = @[]): Multi =
  ## Добавя DELETE стъпка към Multi.
  result = multi
  result.steps.add(MultiStep(
    name: name,
    dependsOn: dependsOn,
    fn: proc (repo: Repo, ctx: MultiContext): (pointer, string) =
      try:
        discard repo.delete(cs)
        (nil, "")
      except CatchableError as e:
        (nil, e.msg)
  ))

proc run*(multi: Multi, name: string, fn: proc (repo: Repo, ctx: MultiContext): (pointer, string); dependsOn: seq[string] = @[]): Multi =
  ## Добавя custom стъпка (произволен proc) към Multi.
  result = multi
  result.steps.add(MultiStep(
    name: name,
    dependsOn: dependsOn,
    fn: fn
  ))

proc transactionMulti*(repo: Repo, multi: Multi): MultiContext =
  ## Изпълнява всички стъпки в Multi атомарно в транзакция.
  ## Ако която и да е стъпка fail-не, хвърля RollbackError.
  ## Връща MultiContext с резултатите от всяка стъпка.
  multi.validateDependencies()
  var ctx = initTable[string, pointer]()
  var failedStep = ""
  var failedErr = ""

  proc body() =
    for step in multi.steps:
      let (res, err) = step.fn(repo, ctx)
      if err.len > 0:
        failedStep = step.name
        failedErr = err
        raise newException(RollbackError, "Multi step '" & step.name & "' failed: " & err)
      ctx[step.name] = res

  repo.transaction(body)

  if failedStep.len > 0:
    raise newException(RollbackError, "Multi step '" & failedStep & "' failed: " & failedErr)

  ctx
