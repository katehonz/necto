## Test schema compilation
import necto

necto_schema User:
  table "users"
  field id: int64 {.primary_key.}
  field name: string
  field email: string
  field age: int
  timestamps
  belongs_to team: Team

necto_schema Team:
  table "teams"
  field id: int64 {.primary_key.}
  field name: string

echo "Schema defined OK"
echo "User table: ", UserSchema.tableName
echo "User fields count: ", UserSchema.fields.len
for f in UserSchema.fields:
  echo "  ", f.name, " -> ", f.dbColumn, " (", f.dbType, ")"
echo "Team table: ", TeamSchema.tableName
echo "Team fields count: ", TeamSchema.fields.len
for f in TeamSchema.fields:
  echo "  ", f.name, " -> ", f.dbColumn, " (", f.dbType, ")"
