## Тест за новите типове от Фаза 1
## JsonNode, Date, TimeOfDay, Uuid, int16

import std/[unittest, tables, options, json]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

# --- Schema с всички нови типове ---

necto_schema Product:
  table "test_products_types"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}
  field stock: int16
  field metadata: JsonNode
  field released_on: Date
  field available_at: TimeOfDay
  field serial: Uuid
  timestamps

suite "New types: JsonNode, Date, TimeOfDay, Uuid, int16":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_products_types\"")
    testrepoInstance.exec("""
      CREATE TABLE "test_products_types" (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        stock SMALLINT,
        metadata JSONB,
        released_on DATE,
        available_at TIME WITHOUT TIME ZONE,
        serial UUID,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """)

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS \"test_products_types\"")

  test "Insert and load JsonNode field":
    var meta = %*{"color": "red", "tags": ["sale", "new"]}
    var cs = newChangeset(newProduct(), {
      "name": "Widget",
      "stock": "42",
      "metadata": $meta,
      "released_on": "2024-05-27",
      "available_at": "14:30:00",
      "serial": "550e8400-e29b-41d4-a716-446655440000"
    }.toTable)
    cs = cs.castFields(@["name", "stock", "metadata", "released_on", "available_at", "serial"])
    check(cs.isValid)

    let p = testrepoInstance.insert(cs)
    check(p.name == "Widget")
    check(p.stock == 42)
    check(p.metadata.kind == JObject)
    check(p.metadata["color"].getStr == "red")
    check(p.released_on.year == 2024)
    check(p.released_on.month == 5)
    check(p.released_on.day == 27)
    check(p.available_at.hour == 14)
    check(p.available_at.minute == 30)
    check(p.available_at.second == 0)
    check(p.serial == Uuid("550e8400-e29b-41d4-a716-446655440000"))

  test "Query with new types":
    var meta = %*{"category": "electronics"}
    var cs1 = newChangeset(newProduct(), {
      "name": "Phone",
      "stock": "10",
      "metadata": $meta,
      "released_on": "2023-01-15",
      "available_at": "09:00:00",
      "serial": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }.toTable)
    cs1 = cs1.castFields(@["name", "stock", "metadata", "released_on", "available_at", "serial"])
    discard testrepoInstance.insert(cs1)

    var cs2 = newChangeset(newProduct(), {
      "name": "Tablet",
      "stock": "5",
      "metadata": "null",
      "released_on": "2024-06-01",
      "available_at": "10:00:00",
      "serial": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    }.toTable)
    cs2 = cs2.castFields(@["name", "stock", "metadata", "released_on", "available_at", "serial"])
    discard testrepoInstance.insert(cs2)

    let products = testrepoInstance.all(fromSchema(Product).orderBy("id", Asc))
    check(products.len == 2)
    check(products[0].name == "Phone")
    check(products[0].stock == 10)
    check(products[1].name == "Tablet")
    check(products[1].stock == 5)

  test "Type system roundtrip":
    ## Проверява loadValue/dumpValue за всеки нов тип
    let meta = loadValue("{\"key\": \"val\"}", JsonNode)
    check(meta["key"].getStr == "val")
    check(dumpValue(meta) == """{"key":"val"}""")

    let d = loadValue("2024-12-25", Date)
    check(d.year == 2024)
    check(d.month == 12)
    check(d.day == 25)
    check(dumpValue(d) == "2024-12-25")

    let t = loadValue("16:45:30", TimeOfDay)
    check(t.hour == 16)
    check(t.minute == 45)
    check(t.second == 30)
    check(dumpValue(t) == "16:45:30")

    let u = loadValue("12345678-1234-1234-1234-123456789abc", Uuid)
    check(u == Uuid("12345678-1234-1234-1234-123456789abc"))
    check(dumpValue(u) == "12345678-1234-1234-1234-123456789abc")

    let i16 = loadValue("32767", int16)
    check(i16 == 32767)
    check(dumpValue(i16) == "32767")
