## Тест за PostgreSQL-специфични типове

import std/[unittest, tables]
import ../src/necto
import ../src/necto/postgres_types
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema GeoItem:
  table "test_geo_items"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field location: PgPoint
  field ip: PgInet
  field mac: PgMacAddr
  field search_vec: PgTsVector
  field balance: Money
  timestamps

suite "PostgreSQL-specific types":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_geo_items\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_geo_items" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        location POINT,
        ip INET,
        mac MACADDR,
        search_vec TSVECTOR,
        balance BIGINT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_geo_items\"")

  test "Insert and load PostgreSQL-specific types":
    var cs = newChangeset(newGeoItem(), {
      "name": "Server A",
      "location": "(3.5,4.2)",
      "ip": "192.168.1.1",
      "mac": "08:00:2b:01:02:03",
      "search_vec": "'hello' & 'world'",
      "balance": "9999"
    }.toTable)
    cs = cs.castFields(@["name", "location", "ip", "mac", "search_vec", "balance"])
    check(cs.isValid)

    let item = testrepoInstance.insert(cs)
    check(item.name == "Server A")
    check(item.location == PgPoint(x: 3.5, y: 4.2))
    check(item.ip == PgInet("192.168.1.1"))
    check(item.mac == PgMacAddr("08:00:2b:01:02:03"))
    check(item.search_vec != PgTsVector(""))  # PostgreSQL нормализира tsvector
    check(item.balance == Money(9999))

  test "Type system roundtrip — PgPoint":
    let p = loadValue("(1.5,-2.3)", PgPoint)
    check(p.x == 1.5)
    check(p.y == -2.3)
    check(dumpValue(p) == "(1.5,-2.3)")

  test "Type system roundtrip — PgInet":
    let ip = loadValue("10.0.0.1/24", PgInet)
    check(ip == PgInet("10.0.0.1/24"))
    check(dumpValue(ip) == "10.0.0.1/24")

  test "Type system roundtrip — PgMacAddr":
    let mac = loadValue("aa:bb:cc:dd:ee:ff", PgMacAddr)
    check(mac == PgMacAddr("aa:bb:cc:dd:ee:ff"))

  test "Type system roundtrip — Money":
    let m = loadValue("1500", Money)
    check(m == Money(1500))
    check(dumpValue(m) == "1500")

  test "Schema generator recognizes PostgreSQL types":
    ## Проверяваме че schema_generator ще мапне правилно PostgreSQL типовете
    check(pgTypeToNim("point") == "PgPoint")
    check(pgTypeToNim("inet") == "PgInet")
    check(pgTypeToNim("macaddr") == "PgMacAddr")
    check(pgTypeToNim("tsvector") == "PgTsVector")
