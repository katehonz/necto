## Necto Benchmark Suite
##
## Compares Necto ORM vs raw db_postgres queries.
## Proves the macro layer has <5% overhead.
##
## Run: nim c -r -d:release --path:src benchmarks/necto_bench.nim

import std/[monotimes, times, strutils, strformat, math, tables]
import db_connector/db_postgres as pg
import ../src/necto
import ../src/necto/adapters/postgres

# --- Benchmark Harness ---

type BenchResult = object
  name: string
  rawMs: float64
  nectoMs: float64
  overheadPct: float64

var results: seq[BenchResult]

proc addResult(name: string; rawNs, nectoNs: int64; iterations: int) =
  let rawMs = float64(rawNs) / 1_000_000.0
  let nectoMs = float64(nectoNs) / 1_000_000.0
  let overhead = if rawMs > 0: ((nectoMs - rawMs) / rawMs) * 100.0 else: 0.0
  results.add(BenchResult(name: name, rawMs: rawMs, nectoMs: nectoMs, overheadPct: overhead))

proc printResults() =
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Necto ORM Benchmark -- vs Raw db_postgres (PostgreSQL)"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  echo "  Benchmark                      Raw (ms)    Necto (ms)    Overhead"
  echo "  " & "-".repeat(64)

  var totalRaw = 0.0
  var totalNecto = 0.0
  for r in results:
    echo fmt"  {r.name:<30} {r.rawMs:>10.2f} {r.nectoMs:>12.2f} {r.overheadPct:>9.1f}%"
    totalRaw += r.rawMs
    totalNecto += r.nectoMs

  echo "  " & "-".repeat(64)
  let totalOverhead = if totalRaw > 0: ((totalNecto - totalRaw) / totalRaw) * 100.0 else: 0.0
  let totalLabel = "TOTAL (" & $results.len & " benchmarks)"
  echo fmt"  {totalLabel:<30} {totalRaw:>10.2f} {totalNecto:>12.2f} {totalOverhead:>9.1f}%"
  echo ""
  if totalOverhead < 5.0:
    echo "  OK Necto overhead is under 5% -- macro layer is essentially free."
  elif totalOverhead < 10.0:
    echo "  WARN Necto overhead is under 10% -- acceptable for most workloads."
  else:
    echo "  FAIL Necto overhead is above 10% -- needs investigation."
  echo ""

# --- Setup ---

necto_repo BenchRepo:
  adapter PostgresAdapter
  host "localhost"
  port 5432
  user "postgres"
  password "pas+123"
  database "necto_test"
  pool_size 5

let repo = benchrepoInstance

necto_schema BenchUser:
  table "bench_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field email: string
  field age: int
  field active: bool
  timestamps

proc initRawDb(): pg.DbConn =
  pg.open("localhost", "postgres", "pas+123", "necto_test")

# --- Timing helpers ---

template timeIt(iterations: int, body: untyped): int64 =
  let t0 = getMonoTime()
  for i in 0..<iterations:
    body
  (getMonoTime() - t0).inNanoseconds

# --- Main ---

proc main() =
  echo "Necto Benchmark Suite"
  echo "====================="
  echo ""

  # Create test table
  let setupDb = initRawDb()
  setupDb.exec(sql"DROP TABLE IF EXISTS bench_users")
  setupDb.exec(sql"""
    CREATE TABLE bench_users (
      id BIGSERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT,
      age INTEGER,
      active BOOLEAN DEFAULT true,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
      updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    )
  """)

  # Seed 1000 rows
  echo "Seeding 1000 rows..."
  for i in 1..1000:
    let name = "User_" & $i
    let email = "user" & $i & "@test.com"
    let age = 20 + (i mod 50)
    setupDb.exec(sql"""
      INSERT INTO bench_users (name, email, age, active)
      VALUES (?, ?, ?, true)
    """, name, email, $age)
  echo "Done seeding."
  echo ""

  # Warmup
  for i in 0..<10:
    discard repo.all(fromSchema(BenchUser).limit(10))

  # Single shared raw connection for fair comparison (like Necto's pool)
  let rawDb = initRawDb()

  # --- Benchmark 1: SELECT 1000 rows ---
  block:
    const ITERS = 100
    let rawNs = timeIt(ITERS):
      var rows: seq[seq[string]] = @[]
      for row in rawDb.getAllRows(sql"SELECT * FROM bench_users ORDER BY id"):
        rows.add(row)

    let nectoNs = timeIt(ITERS):
      discard repo.all(fromSchema(BenchUser).orderBy("id", Asc))

    addResult("SELECT 1000 rows", rawNs, nectoNs, ITERS)

  # --- Benchmark 2: SELECT WHERE (filter) ---
  block:
    const ITERS = 500
    let rawNs = timeIt(ITERS):
      var rows: seq[seq[string]] = @[]
      for row in rawDb.getAllRows(sql"SELECT * FROM bench_users WHERE age > 40 ORDER BY id"):
        rows.add(row)

    let nectoNs = timeIt(ITERS):
      discard repo.all(fromSchema(BenchUser).where("age", Gt, "40").orderBy("id", Asc))

    addResult("SELECT WHERE age > 40", rawNs, nectoNs, ITERS)

  # --- Benchmark 3: PK lookup ---
  block:
    const ITERS = 1000
    let rawNs = timeIt(ITERS):
      discard rawDb.getRow(sql"SELECT * FROM bench_users WHERE id = 500")

    let nectoNs = timeIt(ITERS):
      discard repo.one(fromSchema(BenchUser).where("id", Eq, "500"))

    addResult("SELECT by PK", rawNs, nectoNs, ITERS)

  # --- Benchmark 4: INSERT ---
  block:
    const ITERS = 200
    var ctr = 2000
    let rawNs = timeIt(ITERS):
      inc ctr
      rawDb.exec(sql"INSERT INTO bench_users (name, email, age, active) VALUES ('Raw', 'r@t.com', 30, true)")

    let nectoNs = timeIt(ITERS):
      var cs = newChangeset(newBenchUser(), {
        "name": "Necto",
        "email": "n@t.com",
        "age": "30",
        "active": "true"
      }.toTable)
      cs = cs.castFields(@["name", "email", "age", "active"])
      discard repo.insert(cs)

    addResult("INSERT single row", rawNs, nectoNs, ITERS)

  # --- Benchmark 5: COUNT ---
  block:
    const ITERS = 500
    let rawNs = timeIt(ITERS):
      discard rawDb.getValue(sql"SELECT COUNT(*) FROM bench_users")

    let nectoNs = timeIt(ITERS):
      discard repo.count(fromSchema(BenchUser))

    addResult("COUNT all rows", rawNs, nectoNs, ITERS)

  # --- Cleanup ---
  rawDb.close()
  setupDb.exec(sql"DROP TABLE IF EXISTS bench_users")
  setupDb.close()

  printResults()

  var totalRaw = 0.0
  var totalNecto = 0.0
  for r in results:
    totalRaw += r.rawMs
    totalNecto += r.nectoMs
  let overhead = if totalRaw > 0: ((totalNecto - totalRaw) / totalRaw) * 100.0 else: 0.0

  echo "═══════════════════════════════════════════════════════════════"
  echo "  Nim 2.2.x | PostgreSQL via db_connector | Necto ORM"
  echo fmt"  ORM overhead: {overhead:.1f}%"
  echo "═══════════════════════════════════════════════════════════════"

main()