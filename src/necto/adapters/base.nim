## Necto Adapter Base
##
## Интерфейс за database adapters. Всеки адаптер трябва да имплементира
## основните CRUD операции и транзакции.

import std/[options, tables]

type
  DbRow* = seq[string]
    ## Ред от базата данни като seq от низове.

  Adapter* = ref object of RootObj
    ## Абстрактен базов адаптер.
    host*: string
    port*: int
    user*: string
    password*: string
    database*: string
    poolSize*: int

  Connection* = ref object of RootObj
    ## Абстрактна връзка.

# --- Абстрактни методи ---

method connect*(a: Adapter): Connection {.base.} =
  raise newException(Defect, "connect not implemented")

method disconnect*(a: Adapter, conn: Connection) {.base.} =
  raise newException(Defect, "disconnect not implemented")

method query*(a: Adapter, conn: Connection, sql: string, args: seq[string] = @[]): seq[DbRow] {.base.} =
  raise newException(Defect, "query not implemented")

method exec*(a: Adapter, conn: Connection, sql: string, args: seq[string] = @[]) {.base.} =
  raise newException(Defect, "exec not implemented")

method scalar*(a: Adapter, conn: Connection, sql: string, args: seq[string] = @[]): string {.base.} =
  raise newException(Defect, "scalar not implemented")

method beginTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(Defect, "beginTransaction not implemented")

method commitTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(Defect, "commitTransaction not implemented")

method rollbackTransaction*(a: Adapter, conn: Connection) {.base.} =
  raise newException(Defect, "rollbackTransaction not implemented")
