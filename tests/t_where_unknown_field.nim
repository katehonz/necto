discard """
  errormsg: "Unknown field 'nope'"
"""

## Compile-fail: `where("nope", …)` must be rejected against the schema.

import ../src/necto

necto_schema WhereUnknownUser:
  table "wu_users"
  field id: int64 {.primary_key.}
  field name: string

let q = fromSchema(WhereUnknownUser).where("nope", Eq, "x")
discard q
