import std/macros

macro showAst(body: untyped): untyped =
  echo "=== AST ==="
  echo body.treeRepr
  result = newStmtList()

showAst:
  table "users"
  field id: int64 {.primary_key.}
  field name: string
  field email: string
  field age: int
  timestamps
  belongs_to team: Team
