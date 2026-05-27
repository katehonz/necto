## Necto Type System
##
## Cast, load и dump между Nim типове и PostgreSQL типове.
##
## === NectoType конвенция (формален интерфейс за custom типове) ===
##
## За да дефинирате свой собствен тип, който работи с necto_schema,
## overload-нете следните 4 proc-а:
##
##   proc dbType*(T: typedesc[MyType]): string
##     → връща PostgreSQL името на типа (напр. "bigint", "numeric")
##
##   proc castValue*(val: string, T: typedesc[MyType]): MyType
##     → конвертира от user input (HTTP params, форми) към Nim стойност
##
##   proc loadValue*(val: string, T: typedesc[MyType]): MyType
##     → конвертира от PostgreSQL резултат (текстов формат) към Nim стойност
##
##   proc dumpValue*(val: MyType): string
##     → конвертира от Nim стойност към PostgreSQL-съвместим текстов формат
##
##  Препоръчително (но не задължително):
##   proc `$`*(val: MyType): string   — за debug/display
##   proc `==`*(a, b: MyType): bool  — за сравнение
##
##  След като дефинирате типа и overload-нете proc-овете, регистрирайте го
##  чрез registerNectoType, за да работи в necto_schema макрото:
##
##   registerNectoType(MyType)
##
##  Пример — виж Money типът в postgres_types.nim.
##
##  Тази конвенция е вдъхновена от Ecto.Type behaviour (Elixir):
##    type/0   → dbType
##    cast/1   → castValue
##    load/1   → loadValue
##    dump/1   → dumpValue

import std/[strutils, options, json, times, tables]

# --- Custom type registry (compile-time) ---

var nectoTypeRegistry {.compileTime.}: Table[string, string]

template registerNectoType*(T: typedesc) =
  ## Регистрира custom тип за използване в necto_schema макрото.
  ## Трябва да се извика СЛЕД като сте overload-нали dbType, castValue, loadValue, dumpValue.
  ##
  ## Пример:
  ##   type MyMoney = distinct int64
  ##   proc dbType*(T: typedesc[MyMoney]): string = "bigint"
  ##   proc loadValue*(val: string, T: typedesc[MyMoney]): MyMoney = MyMoney(parseBiggestInt(val))
  ##   proc dumpValue*(val: MyMoney): string = $int64(val)
  ##   proc castValue*(val: string, T: typedesc[MyMoney]): MyMoney = MyMoney(parseBiggestInt(val))
  ##   registerNectoType(MyMoney)
  static:
    nectoTypeRegistry[$T] = dbType(T)

proc resolveCustomDbType*(nimTypeStr: string): string {.compileTime.} =
  ## Проверява custom type registry-то за подадения Nim тип (като низ).
  ## Връща dbType стринга или празен низ ако типът не е регистриран.
  if nimTypeStr in nectoTypeRegistry:
    result = nectoTypeRegistry[nimTypeStr]
  else:
    result = ""

# --- Custom types ---

type
  Uuid* = distinct string
  Date* = object
    year*: int
    month*: int
    day*: int
  TimeOfDay* = object
    hour*: int
    minute*: int
    second*: int
  Decimal* = distinct string
  FixedDecimal*[Scale: static int] = object
    ## Fixed-point decimal с int64 backing store.
    ## Scale е броят знаци след десетичната запетая.
    ## Пример: FixedDecimal[2] с raw=12345 = 123.45
    raw*: int64

proc tenPow(n: static int): int64 {.compileTime.} =
  result = 1'i64
  for i in 1..n:
    result *= 10'i64

proc `==`*[S: static int](a, b: FixedDecimal[S]): bool = a.raw == b.raw
proc `<`*[S: static int](a, b: FixedDecimal[S]): bool = a.raw < b.raw
proc `<=`*[S: static int](a, b: FixedDecimal[S]): bool = a.raw <= b.raw
proc `>`*[S: static int](a, b: FixedDecimal[S]): bool = a.raw > b.raw
proc `>=`*[S: static int](a, b: FixedDecimal[S]): bool = a.raw >= b.raw

proc `$`*[S: static int](d: FixedDecimal[S]): string =
  const pow10 = tenPow(S)
  let sign = if d.raw < 0: "-" else: ""
  let absRaw = abs(d.raw)
  let intPart = absRaw div pow10
  let fracPart = absRaw mod pow10
  let fracStr = intToStr(fracPart.int, S)
  sign & $intPart & "." & fracStr

proc fromFloat*[S: static int](val: float): FixedDecimal[S] =
  ## Създава FixedDecimal от float.
  const pow10 = tenPow(S)
  FixedDecimal[S](raw: int64(val * float(pow10)))

proc fromString*[S: static int](val: string): FixedDecimal[S] =
  ## Създава FixedDecimal от string.
  let f = parseFloat(val)
  fromFloat[S](f)

proc `+`*[S: static int](a, b: FixedDecimal[S]): FixedDecimal[S] =
  FixedDecimal[S](raw: a.raw + b.raw)

proc `-`*[S: static int](a, b: FixedDecimal[S]): FixedDecimal[S] =
  FixedDecimal[S](raw: a.raw - b.raw)

proc `*`*[S: static int](a, b: FixedDecimal[S]): FixedDecimal[S] =
  ## Умножение с корекция на scale.
  const pow10 = tenPow(S)
  FixedDecimal[S](raw: (a.raw * b.raw) div pow10)

proc `/`*[S: static int](a, b: FixedDecimal[S]): FixedDecimal[S] =
  ## Делене с корекция на scale.
  const pow10 = tenPow(S)
  FixedDecimal[S](raw: (a.raw * pow10) div b.raw)

proc dbType*[S: static int](T: typedesc[FixedDecimal[S]]): string = "numeric"
proc loadValue*[S: static int](val: string, T: typedesc[FixedDecimal[S]]): FixedDecimal[S] =
  fromString[S](val)
proc dumpValue*[S: static int](val: FixedDecimal[S]): string = $val
proc castValue*[S: static int](val: string, T: typedesc[FixedDecimal[S]]): FixedDecimal[S] =
  fromString[S](val)

proc `==`*(a, b: Uuid): bool = string(a) == string(b)
proc `$`*(u: Uuid): string = string(u)
proc `$`*(d: Date): string =
  d.year.intToStr(4) & "-" & d.month.intToStr(2) & "-" & d.day.intToStr(2)
proc `$`*(t: TimeOfDay): string =
  t.hour.intToStr(2) & ":" & t.minute.intToStr(2) & ":" & t.second.intToStr(2)
proc `$`*(d: Decimal): string = string(d)
proc `==`*(a, b: Decimal): bool = string(a) == string(b)

# --- Built-in dbType mappings ---

proc dbType*(T: typedesc[string]): string = "text"
proc dbType*(T: typedesc[int]): string = "integer"
proc dbType*(T: typedesc[int16]): string = "smallint"
proc dbType*(T: typedesc[int64]): string = "bigint"
proc dbType*(T: typedesc[float]): string = "double precision"
proc dbType*(T: typedesc[bool]): string = "boolean"
proc dbType*(T: typedesc[DateTime]): string = "timestamp with time zone"
proc dbType*(T: typedesc[Date]): string = "date"
proc dbType*(T: typedesc[TimeOfDay]): string = "time without time zone"
proc dbType*(T: typedesc[JsonNode]): string = "jsonb"
proc dbType*(T: typedesc[Uuid]): string = "uuid"
proc dbType*(T: typedesc[Decimal]): string = "numeric"
proc dbType*(T: typedesc[seq[byte]]): string = "bytea"

proc dbType*[T](OptT: typedesc[Option[T]]): string = dbType(T)
proc dbType*[T](SeqT: typedesc[seq[T]]): string = dbType(T) & "[]"

proc dbType*[T: enum](EnumT: typedesc[T]): string = "text"

# --- Cast from raw string input (e.g., HTTP params) ---

proc castValue*(val: string, T: typedesc[string]): string = val
proc castValue*(val: string, T: typedesc[int]): int = parseInt(val)
proc castValue*(val: string, T: typedesc[int64]): int64 = parseBiggestInt(val)
proc castValue*(val: string, T: typedesc[int16]): int16 = int16(parseInt(val))
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

proc castValue*(val: string, T: typedesc[Date]): Date =
  ## Parse ISO 8601 date от низ.
  let dt = parse(val, "yyyy-MM-dd")
  result = Date(year: dt.year, month: dt.month.int, day: dt.monthday.int)

proc castValue*(val: string, T: typedesc[TimeOfDay]): TimeOfDay =
  ## Parse ISO 8601 time от низ.
  let dt = parse(val, "HH:mm:ss")
  result = TimeOfDay(hour: dt.hour.int, minute: dt.minute.int, second: dt.second.int)

proc castValue*(val: string, T: typedesc[Uuid]): Uuid =
  Uuid(val)

proc castValue*(val: string, T: typedesc[JsonNode]): JsonNode =
  parseJson(val)

proc castValue*(val: string, T: typedesc[Decimal]): Decimal =
  Decimal(val)

proc castValue*[T: enum](val: string, OptT: typedesc[T]): T =
  ## Cast enum от низ — поддържа име или пореден номер.
  try:
    result = parseEnum[T](val)
  except ValueError:
    result = T(parseInt(val))

# --- PostgreSQL array parser ---

proc parsePgArray*(val: string): seq[string] =
  ## Парсира PostgreSQL array текстов формат в елементи.
  ## Поддържа quoting, escaping, NULL и вложени масиви.
  ## Примери: {1,2,3}  {"a","b"}  {{1,2},{3,4}}
  if val.len < 2 or val[0] != '{' or val[^1] != '}':
    return @[val]
  if val == "{}":
    return @[]

  result = @[]
  var i = 1
  while i < val.len - 1:
    if val[i] == ',':
      inc i
      continue

    var elem = ""
    if val[i] == '"':
      # quoted element
      inc i
      while i < val.len - 1:
        if val[i] == '\\' and i + 1 < val.len:
          inc i
          elem.add(val[i])
        elif val[i] == '"':
          inc i
          break
        else:
          elem.add(val[i])
        inc i
    else:
      # unquoted element (could be nested array like {1,2} or plain text)
      var depth = 0
      while i < val.len - 1:
        if val[i] == '{':
          inc depth
          elem.add(val[i])
        elif val[i] == '}':
          if depth > 0:
            dec depth
            elem.add(val[i])
          else:
            break
        elif val[i] == ',' and depth == 0:
          break
        else:
          elem.add(val[i])
        inc i

    result.add(elem.strip())

    if i < val.len - 1 and val[i] == ',':
      inc i

proc castValue*[T](val: string, OptT: typedesc[seq[T]]): seq[T] =
  ## Cast seq[T] от PostgreSQL array текстов формат.
  if val.len == 0 or val == "{}":
    return @[]
  let elements = parsePgArray(val)
  result = @[]
  for elem in elements:
    if elem == "NULL":
      continue
    result.add(castValue(elem, T))

# --- Load from DB row string ---

# --- Zero-allocation array loading (slice-based) ---

iterator pgArrayElements(val: string): tuple[start, stop: int] =
  ## Yield start/stop indices for each element in PostgreSQL array format.
  ## Does NOT allocate intermediate strings.
  if val.len >= 2 and val[0] == '{' and val[^1] == '}':
    if val != "{}":
      var i = 1
      while i < val.len - 1:
        if val[i] == ',':
          inc i
          continue
        var start = i
        if val[i] == '"':
          inc i
          start = i
          while i < val.len - 1:
            if val[i] == '\\' and i + 1 < val.len:
              inc i, 2
            elif val[i] == '"':
              break
            else:
              inc i
          yield (start, i)
          if i < val.len and val[i] == '"':
            inc i
        else:
          var depth = 0
          while i < val.len - 1:
            if val[i] == '{':
              inc depth
            elif val[i] == '}':
              if depth > 0:
                dec depth
              else:
                break
            elif val[i] == ',' and depth == 0:
              break
            inc i
          yield (start, i)
        while i < val.len - 1 and val[i] == ',':
          inc i

proc loadValueSlice*(val: string, start, stop: int, T: typedesc[int]): int =
  ## Parse int directly from a string slice (zero-allocation).
  if stop <= start: return 0
  var i = start
  var negative = false
  if val[i] == '-':
    negative = true
    inc i
  result = 0
  while i < stop and val[i] in {'0'..'9'}:
    result = result * 10 + (val[i].ord - '0'.ord)
    inc i
  if negative: result = -result

proc loadValueSlice*(val: string, start, stop: int, T: typedesc[int64]): int64 =
  ## Parse int64 directly from a string slice (zero-allocation).
  if stop <= start: return 0'i64
  var i = start
  var negative = false
  if val[i] == '-':
    negative = true
    inc i
  result = 0'i64
  while i < stop and val[i] in {'0'..'9'}:
    result = result * 10'i64 + (val[i].ord - '0'.ord).int64
    inc i
  if negative: result = -result

proc loadValueSlice*(val: string, start, stop: int, T: typedesc[float]): float =
  ## Parse float directly from a string slice (minimal allocation).
  if stop <= start: return 0.0
  result = parseFloat(val[start ..< stop])

proc loadValueSlice*(val: string, start, stop: int, T: typedesc[bool]): bool =
  ## Parse bool directly from a string slice (zero-allocation).
  if stop <= start: return false
  if val[start] == 't': return true
  if stop - start == 1 and val[start] == '1': return true
  return false

proc loadPgArray*(val: string, T: typedesc[seq[int]]): seq[int] =
  ## Fast zero-allocation load for seq[int].
  if val.len == 0 or val == "{}": return @[]
  result = @[]
  for (s, e) in pgArrayElements(val):
    if e - s == 4 and val[s..<e] == "NULL": continue
    result.add(loadValueSlice(val, s, e, int))

proc loadPgArray*(val: string, T: typedesc[seq[int64]]): seq[int64] =
  ## Fast zero-allocation load for seq[int64].
  if val.len == 0 or val == "{}": return @[]
  result = @[]
  for (s, e) in pgArrayElements(val):
    if e - s == 4 and val[s..<e] == "NULL": continue
    result.add(loadValueSlice(val, s, e, int64))

proc loadPgArray*(val: string, T: typedesc[seq[float]]): seq[float] =
  ## Fast load for seq[float] (uses one temporary string per element).
  if val.len == 0 or val == "{}": return @[]
  result = @[]
  for (s, e) in pgArrayElements(val):
    if e - s == 4 and val[s..<e] == "NULL": continue
    result.add(loadValueSlice(val, s, e, float))

proc loadPgArray*(val: string, T: typedesc[seq[bool]]): seq[bool] =
  ## Fast zero-allocation load for seq[bool].
  if val.len == 0 or val == "{}": return @[]
  result = @[]
  for (s, e) in pgArrayElements(val):
    if e - s == 4 and val[s..<e] == "NULL": continue
    result.add(loadValueSlice(val, s, e, bool))

proc loadValue*(val: string, T: typedesc[string]): string =
  ## Load стринг от БД (просто връща стойността).
  val

proc loadValue*(val: string, T: typedesc[int]): int =
  if val.len == 0: 0 else: parseInt(val)

proc loadValue*(val: string, T: typedesc[int16]): int16 =
  if val.len == 0: 0'i16 else: int16(parseInt(val))

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

proc loadValue*(val: string, T: typedesc[Date]): Date =
  ## Load Date от PostgreSQL date string.
  if val.len == 0:
    result = Date(year: 1970, month: 1, day: 1)
    return
  try:
    let dt = parse(val, "yyyy-MM-dd")
    result = Date(year: dt.year, month: dt.month.int, day: dt.monthday.int)
  except:
    raise newException(ValueError, "Cannot load Date: " & val)

proc loadValue*(val: string, T: typedesc[TimeOfDay]): TimeOfDay =
  ## Load TimeOfDay от PostgreSQL time string.
  if val.len == 0:
    result = TimeOfDay(hour: 0, minute: 0, second: 0)
    return
  try:
    let dt = parse(val, "HH:mm:ss")
    result = TimeOfDay(hour: dt.hour.int, minute: dt.minute.int, second: dt.second.int)
  except ValueError:
    try:
      let dt = parse(val, "HH:mm:ss'.'fff")
      result = TimeOfDay(hour: dt.hour.int, minute: dt.minute.int, second: dt.second.int)
    except:
      raise newException(ValueError, "Cannot load TimeOfDay: " & val)

proc loadValue*(val: string, T: typedesc[JsonNode]): JsonNode =
  ## Load JsonNode от PostgreSQL json/jsonb string.
  if val.len == 0:
    result = newJNull()
  else:
    result = parseJson(val)

proc loadValue*(val: string, T: typedesc[Uuid]): Uuid =
  ## Load Uuid от PostgreSQL uuid string.
  if val.len == 0:
    result = Uuid("")
  else:
    result = Uuid(val)

proc loadValue*(val: string, T: typedesc[Decimal]): Decimal =
  ## Load Decimal от PostgreSQL numeric string.
  if val.len == 0:
    result = Decimal("0")
  else:
    result = Decimal(val)

proc loadValue*[T: enum](val: string, OptT: typedesc[T]): T =
  ## Load enum от PostgreSQL text/integer string.
  if val.len == 0:
    return T(0)
  try:
    result = parseEnum[T](val)
  except ValueError:
    try:
      result = T(parseInt(val))
    except ValueError:
      raise newException(ValueError, "Cannot load enum '" & $T & "' from: " & val)

proc loadValue*(val: string, T: typedesc[seq[int]]): seq[int] =
  ## Load PostgreSQL array → seq[int] (zero-allocation fast path).
  loadPgArray(val, seq[int])

proc loadValue*(val: string, T: typedesc[seq[int64]]): seq[int64] =
  ## Load PostgreSQL array → seq[int64] (zero-allocation fast path).
  loadPgArray(val, seq[int64])

proc loadValue*(val: string, T: typedesc[seq[float]]): seq[float] =
  ## Load PostgreSQL array → seq[float] (fast path).
  loadPgArray(val, seq[float])

proc loadValue*(val: string, T: typedesc[seq[bool]]): seq[bool] =
  ## Load PostgreSQL array → seq[bool] (zero-allocation fast path).
  loadPgArray(val, seq[bool])

proc loadValue*[T](val: string, OptT: typedesc[seq[T]]): seq[T] =
  ## Load PostgreSQL array текстов формат (generic fallback).
  if val.len == 0 or val == "{}":
    return @[]
  let elements = parsePgArray(val)
  result = @[]
  for elem in elements:
    if elem == "NULL":
      continue
    result.add(loadValue(elem, T))

proc loadValue*(val: string, T: typedesc[seq[byte]]): seq[byte] =
  ## Load bytea от PostgreSQL hex escape формат \xDEADBEEF.
  if val.len == 0:
    return @[]
  if val.len >= 2 and val[0] == '\\' and val[1] == 'x':
    let hexStr = val[2..^1]
    result = @[]
    var i = 0
    while i + 1 < hexStr.len:
      let hexByte = hexStr[i..i+1]
      result.add(byte(parseHexInt(hexByte)))
      inc i, 2
  else:
    # escape format fallback
    result = @[]

proc loadValue*[T](val: string, OptT: typedesc[Option[T]]): Option[T] =
  ## Load Option[T] — ако val е празен, връща none.
  if val.len == 0:
    none(T)
  else:
    some(loadValue(val, T))

# --- Dump to DB string ---

proc dumpValue*(val: string): string = val
proc dumpValue*(val: int): string = $val
proc dumpValue*(val: int16): string = $val
proc dumpValue*(val: int64): string = $val
proc dumpValue*(val: float): string = $val
proc dumpValue*(val: bool): string = (if val: "true" else: "false")

proc dumpValue*(val: DateTime): string =
  ## Format DateTime за PostgreSQL.
  val.format("yyyy-MM-dd HH:mm:ss'.'fffzzz")

proc dumpValue*(val: Date): string =
  ## Format Date за PostgreSQL.
  $val

proc dumpValue*(val: TimeOfDay): string =
  ## Format TimeOfDay за PostgreSQL.
  $val

proc dumpValue*(val: JsonNode): string =
  ## Dump JsonNode към PostgreSQL json/jsonb string.
  $val

proc dumpValue*(val: Uuid): string =
  ## Dump Uuid към PostgreSQL uuid string.
  string(val)

proc dumpValue*(val: Decimal): string =
  ## Dump Decimal към PostgreSQL numeric string.
  string(val)

proc dumpValue*[T: enum](val: T): string =
  ## Dump enum като текст (име).
  $val

proc dumpValue*[T](val: Option[T]): string =
  if val.isSome:
    dumpValue(val.get)
  else:
    ""

proc needsPgArrayQuote(s: string): bool =
  ## Проверява дали стойността трябва да се quote-не в PostgreSQL array.
  if s.len == 0: return true
  if s == "NULL": return true
  for c in s:
    if c in {',', '{', '}', '"', '\\', ' ', '\t', '\n', '\r'}:
      return true
  return false

proc escapePgArrayElement(s: string): string =
  ## Escape-ва стойност за PostgreSQL array.
  var r = ""
  for c in s:
    if c == '\\' or c == '"':
      r.add('\\')
    r.add(c)
  result = r

proc dumpValue*[T](val: seq[T]): string =
  ## Dump seq[T] към PostgreSQL array текстов формат.
  if val.len == 0:
    return "{}"
  var parts: seq[string] = @[]
  for item in val:
    let s = dumpValue(item)
    if needsPgArrayQuote(s):
      parts.add('"' & escapePgArrayElement(s) & '"')
    else:
      parts.add(s)
  result = "{" & parts.join(",") & "}"

proc dumpValue*(val: seq[byte]): string =
  ## Dump seq[byte] към PostgreSQL bytea hex формат.
  if val.len == 0:
    return "\\x"
  var hexStr = "\\x"
  for b in val:
    hexStr.add(toHex(int(b), 2).toLowerAscii())
  result = hexStr

# --- Cast raw string to DB-safe string ---

proc castToDb*(val: string, nimTypeStr: string): string =
  ## Валидира и конвертира raw string към DB-съвместим string.
  ## Прави basic type checking според Nim типа.
  case nimTypeStr
  of "string", "text":
    result = val
  of "int", "int32", "integer":
    discard parseInt(val)
    result = val
  of "int16":
    discard parseInt(val)
    result = val
  of "int64", "bigint":
    discard parseBiggestInt(val)
    result = val
  of "float", "float64":
    discard parseFloat(val)
    result = val
  of "bool", "boolean":
    discard parseBool(val)
    result = val
  of "Date":
    discard castValue(val, Date)
    result = val
  of "TimeOfDay":
    discard castValue(val, TimeOfDay)
    result = val
  of "JsonNode":
    discard parseJson(val)
    result = val
  of "Uuid":
    result = val
  of "Decimal":
    discard parseFloat(val)
    result = val
  of "seq[byte]":
    if val.len == 0:
      result = "\\x"
    elif val.len >= 2 and val[0] == '\\' and val[1] == 'x':
      result = val
    else:
      raise newException(ValueError, "Invalid bytea format: " & val)
  else:
    if nimTypeStr.startsWith("Option["):
      if val.len == 0 or val == "null" or val == "nil":
        result = "null"
      else:
        let inner = nimTypeStr[7..^2]
        result = castToDb(val, inner)
    elif nimTypeStr.startsWith("seq["):
      if val.len == 0 or val == "{}":
        result = "{}"
      else:
        # basic validation — must look like an array
        if val[0] != '{' or val[^1] != '}':
          raise newException(ValueError, "Invalid array format: " & val)
        result = val
    else:
      result = val

# --- Typed JSONB (Nim Superpower) ---
##
## JsonB[T] е wrapper който пази JSONB в PostgreSQL но дава типизиран Nim достъп.
## Това е възможно само в compile-to-native език — Ecto не може да го направи.
##
## Пример:
##   type UserSettings = object
##     theme: string
##     notifications: bool
##
##   necto_schema User:
##     field settings: JsonB[UserSettings]
##
##   let user = repo.one(...)
##   echo user.settings.val.theme          # типизиран достъп!
##   echo user.settings.val.notifications

type
  JsonB*[T] = object
    ## Типизиран JSONB wrapper.
    ## Достъп до стойността чрез `.val`.
    val*: T

converter toJsonBInner*[T](jb: JsonB[T]): T =
  ## Автоматично разопакова JsonB[T] → T (за аргументи на функции).
  jb.val

proc dbType*[T](B: typedesc[JsonB[T]]): string = "jsonb"

proc loadValue*[T](val: string, B: typedesc[JsonB[T]]): JsonB[T] =
  ## Load JSONB стринг от PostgreSQL в типизиран JsonB[T].
  if val.len == 0 or val == "null":
    result = JsonB[T](val: default(T))
  else:
    result = JsonB[T](val: parseJson(val).to(T))

proc dumpValue*[T](val: JsonB[T]): string =
  ## Dump типизиран JsonB[T] към PostgreSQL JSONB стринг.
  $ %val.val

proc castValue*[T](val: string, B: typedesc[JsonB[T]]): JsonB[T] =
  ## Cast от user input (JSON стринг) към JsonB[T].
  loadValue(val, JsonB[T])

proc `$`*[T](jb: JsonB[T]): string =
  $ %jb.val

proc `==`*[T](a, b: JsonB[T]): bool =
  $ %a.val == $ %b.val
