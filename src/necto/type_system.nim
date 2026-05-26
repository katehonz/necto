## Necto Type System
##
## Cast, load и dump между Nim типове и PostgreSQL типове.
##
## Потребителите могат да дефинират custom types чрез overload на:
##   proc dbType*(T: typedesc[MyType]): string
##   proc castValue*(val: string, T: typedesc[MyType]): T
##   proc loadValue*(val: string, T: typedesc[MyType]): T
##   proc dumpValue*(val: MyType): string

import std/[strutils, options, json, times]

# --- Built-in dbType mappings ---

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
proc castValue*(val: string, T: typedesc[int64]): int64 = parseBiggestInt(val)
proc castValue*(val: string, T: typedesc[float]): float = parseFloat(val)
proc castValue*(val: string, T: typedesc[bool]): bool = parseBool(val)

proc castValue*(val: string, T: typedesc[DateTime]): DateTime =
  ## Parse ISO 8601 datetime от низ.
  try:
    result = parse(val, "yyyy-MM-dd'T'HH:mm:ss'.'fffzzz")
  except ValueError:
    try:
      result = parse(val, "yyyy-MM-dd HH:mm:ss")
    except ValueError:
      result = parse(val, "yyyy-MM-dd")

# --- Load from DB row string ---

proc loadValue*(val: string, T: typedesc[string]): string =
  ## Load стринг от БД (просто връща стойността).
  val

proc loadValue*(val: string, T: typedesc[int]): int =
  if val.len == 0: 0 else: parseInt(val)

proc loadValue*(val: string, T: typedesc[int64]): int64 =
  if val.len == 0: 0'i64 else: parseBiggestInt(val)

proc loadValue*(val: string, T: typedesc[float]): float =
  if val.len == 0: 0.0 else: parseFloat(val)

proc loadValue*(val: string, T: typedesc[bool]): bool =
  val == "t" or val == "true" or val == "1" or val == "TRUE"

proc normalizePgTimestamp(val: string): string =
  ## Нормализира PostgreSQL timestamp за Nim times.parse.
  ## - Маха fractional seconds (Nim 'fff' е strict)
  ## - Добавя :00 към timezone ако е само +HH / -HH
  result = val
  let dotIdx = result.find('.')
  if dotIdx >= 0:
    var i = dotIdx + 1
    while i < result.len and result[i] in {'0'..'9'}:
      inc i
    result = result[0 ..< dotIdx] & result[i .. ^1]
  if result.len >= 3 and result[^3] in {'+', '-'}:
    result.add(":00")

proc loadValue*(val: string, T: typedesc[DateTime]): DateTime =
  ## Load DateTime от PostgreSQL timestamp string.
  if val.len == 0:
    result = fromUnix(0).utc
    return
  let clean = normalizePgTimestamp(val)
  try:
    result = parse(clean, "yyyy-MM-dd HH:mm:sszzz")
  except ValueError:
    try:
      result = parse(clean, "yyyy-MM-dd HH:mm:ss")
    except:
      raise newException(ValueError, "Cannot load DateTime: " & val & " (normalized: " & clean & ")")

proc loadValue*[T](val: string, OptT: typedesc[Option[T]]): Option[T] =
  ## Load Option[T] — ако val е празен, връща none.
  if val.len == 0:
    none(T)
  else:
    some(loadValue(val, T))

proc loadValue*[T](val: string, OptT: typedesc[seq[T]]): seq[T] =
  ## Load PostgreSQL array. За сега placeholder.
  @[]

# --- Dump to DB string ---

proc dumpValue*(val: string): string = val
proc dumpValue*(val: int): string = $val
proc dumpValue*(val: int64): string = $val
proc dumpValue*(val: float): string = $val
proc dumpValue*(val: bool): string = (if val: "true" else: "false")

proc dumpValue*(val: DateTime): string =
  ## Format DateTime за PostgreSQL.
  val.format("yyyy-MM-dd HH:mm:ss'.'fffzzz")

proc dumpValue*[T](val: Option[T]): string =
  if val.isSome:
    dumpValue(val.get)
  else:
    ""

proc dumpValue*[T](val: seq[T]): string =
  ## Dump PostgreSQL array. За сега placeholder.
  "{}"
