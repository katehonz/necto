## Necto PostgreSQL-specific Types
##
## Optional модул с типове специфични за PostgreSQL.
##
## Потребителят го import-ва изрично:
##   import necto/postgres_types
##
## Всеки тип следва конвенцията:
##   proc dbType*(T: typedesc[MyType]): string
##   proc loadValue*(val: string, T: typedesc[MyType]): MyType
##   proc dumpValue*(val: MyType): string
##   proc castValue*(val: string, T: typedesc[MyType]): MyType

import std/[strutils, parseutils]
import ./type_system

export type_system

# --- PostgreSQL geometric types ---

type
  PgPoint* = object
    x*: float
    y*: float

proc dbType*(T: typedesc[PgPoint]): string = "point"

proc loadValue*(val: string, T: typedesc[PgPoint]): PgPoint =
  ## Parse PostgreSQL point: `(x,y)`
  if val.len < 3 or val[0] != '(' or val[^1] != ')':
    raise newException(ValueError, "Invalid point format: " & val)
  let inner = val[1..^2]
  let parts = inner.split(',')
  if parts.len != 2:
    raise newException(ValueError, "Invalid point format: " & val)
  PgPoint(x: parseFloat(parts[0].strip()), y: parseFloat(parts[1].strip()))

proc dumpValue*(val: PgPoint): string =
  "(" & $val.x & "," & $val.y & ")"

proc castValue*(val: string, T: typedesc[PgPoint]): PgPoint =
  loadValue(val, PgPoint)

proc `$`*(p: PgPoint): string =
  dumpValue(p)

# --- PostgreSQL network types ---

type
  PgInet* = distinct string
  PgCidr* = distinct string
  PgMacAddr* = distinct string

proc dbType*(T: typedesc[PgInet]): string = "inet"
proc dbType*(T: typedesc[PgCidr]): string = "cidr"
proc dbType*(T: typedesc[PgMacAddr]): string = "macaddr"

proc loadValue*(val: string, T: typedesc[PgInet]): PgInet = PgInet(val)
proc loadValue*(val: string, T: typedesc[PgCidr]): PgCidr = PgCidr(val)
proc loadValue*(val: string, T: typedesc[PgMacAddr]): PgMacAddr = PgMacAddr(val)

proc dumpValue*(val: PgInet): string = string(val)
proc dumpValue*(val: PgCidr): string = string(val)
proc dumpValue*(val: PgMacAddr): string = string(val)

proc castValue*(val: string, T: typedesc[PgInet]): PgInet = PgInet(val)
proc castValue*(val: string, T: typedesc[PgCidr]): PgCidr = PgCidr(val)
proc castValue*(val: string, T: typedesc[PgMacAddr]): PgMacAddr = PgMacAddr(val)

proc `$`*(v: PgInet): string = string(v)
proc `$`*(v: PgCidr): string = string(v)
proc `$`*(v: PgMacAddr): string = string(v)

proc `==`*(a, b: PgInet): bool = string(a) == string(b)
proc `==`*(a, b: PgCidr): bool = string(a) == string(b)
proc `==`*(a, b: PgMacAddr): bool = string(a) == string(b)

# --- PostgreSQL text search types ---

type
  PgTsVector* = distinct string
  PgTsQuery* = distinct string

proc dbType*(T: typedesc[PgTsVector]): string = "tsvector"
proc dbType*(T: typedesc[PgTsQuery]): string = "tsquery"

proc loadValue*(val: string, T: typedesc[PgTsVector]): PgTsVector = PgTsVector(val)
proc loadValue*(val: string, T: typedesc[PgTsQuery]): PgTsQuery = PgTsQuery(val)

proc dumpValue*(val: PgTsVector): string = string(val)
proc dumpValue*(val: PgTsQuery): string = string(val)

proc castValue*(val: string, T: typedesc[PgTsVector]): PgTsVector = PgTsVector(val)
proc castValue*(val: string, T: typedesc[PgTsQuery]): PgTsQuery = PgTsQuery(val)

proc `$`*(v: PgTsVector): string = string(v)
proc `$`*(v: PgTsQuery): string = string(v)

proc `==`*(a, b: PgTsVector): bool = string(a) == string(b)
proc `==`*(a, b: PgTsQuery): bool = string(a) == string(b)

# --- Example: Money as fixed-point (cents) ---
##
## Демонстрира custom type със `int64` backing.
## PostgreSQL няма вграден `Money` тип в stdlib, но този пример
## показва как потребителят може да дефинира свой собствен тип.

type Money* = distinct int64

proc dbType*(T: typedesc[Money]): string = "bigint"

proc loadValue*(val: string, T: typedesc[Money]): Money =
  if val.len == 0:
    Money(0)
  else:
    Money(parseBiggestInt(val))

proc dumpValue*(val: Money): string = $int64(val)

proc castValue*(val: string, T: typedesc[Money]): Money =
  Money(parseBiggestInt(val))

proc `$`*(m: Money): string = $int64(m)
proc `==`*(a, b: Money): bool = int64(a) == int64(b)

# --- Регистриране на типовете за necto_schema макрото ---

registerNectoType(PgPoint)
registerNectoType(PgInet)
registerNectoType(PgCidr)
registerNectoType(PgMacAddr)
registerNectoType(PgTsVector)
registerNectoType(PgTsQuery)
registerNectoType(Money)
