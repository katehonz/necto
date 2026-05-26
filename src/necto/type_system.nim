## Necto Type System
##
## Cast, load и dump между Nim типове и PostgreSQL типове.
##
## Потребителите могат да дефинират custom types чрез:
##   proc dbType*(T: typedesc[MyType]): string = "varchar"
##   proc castValue*(val: string, T: typedesc[MyType]): T = ...
##   proc dumpValue*(val: MyType): string = ...

import std/[strutils, options, json, times]

type
  NectoType*[T] = concept t
    ## Концепт за тип, който може да се сериализира/десериализира.
    ## За сега използваме overload-и на прокове, не чист концепт.

# --- Built-in mappings ---

proc dbType*(T: typedesc[string]): string = "text"
proc dbType*(T: typedesc[int]): string = "integer"
proc dbType*(T: typedesc[int64]): string = "bigint"
proc dbType*(T: typedesc[float]): string = "double precision"
proc dbType*(T: typedesc[bool]): string = "boolean"
proc dbType*(T: typedesc[DateTime]): string = "timestamp with time zone"
proc dbType*(T: typedesc[JsonNode]): string = "jsonb"

proc dbType*[T](OptT: typedesc[Option[T]]): string = dbType(T)

# --- Cast from raw string input (e.g., HTTP params) ---

proc castValue*(val: string, T: typedesc[string]): string = val
proc castValue*(val: string, T: typedesc[int]): int = parseInt(val)
proc castValue*(val: string, T: typedesc[int64]): int64 = parseInt(val)
proc castValue*(val: string, T: typedesc[float]): float = parseFloat(val)
proc castValue*(val: string, T: typedesc[bool]): bool = parseBool(val)

# TODO: DateTime, JsonNode, enum cast-ове

# --- Load from DB row string ---

proc loadValue*(val: string, T: typedesc[string]): string = val
proc loadValue*(val: string, T: typedesc[int]): int = parseInt(val)
proc loadValue*(val: string, T: typedesc[int64]): int64 = parseInt(val)
proc loadValue*(val: string, T: typedesc[float]): float = parseFloat(val)
proc loadValue*(val: string, T: typedesc[bool]): bool = val == "t" or val == "true" or val == "1"

# TODO: DateTime, JsonNode, enum load-ове

# --- Dump to DB string ---

proc dumpValue*(val: string): string = val
proc dumpValue*(val: int): string = $val
proc dumpValue*(val: int64): string = $val
proc dumpValue*(val: float): string = $val
proc dumpValue*(val: bool): string = (if val: "true" else: "false")

# TODO: DateTime, JsonNode, enum dump-ове
