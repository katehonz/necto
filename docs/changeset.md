# Changesets

Changesets track, cast, and validate changes before writing to the database.

## Creating a Changeset

```nim
var cs = newChangeset(newUser(), {"name": "Ivan", "email": "ivan@test.com"}.toTable)
```

The first argument is the existing data (or a new object). The second is the raw params map.

## Cast

Whitelist permitted fields and copy them from `params` to `changes`:

```nim
cs = cs.castFields(@["name", "email", "age"])
```

> `castFields` currently copies string values as-is. Type-aware casting is on the roadmap.

## Validations

### validateRequired

```nim
cs = cs.validateRequired(@["name", "email"])
```

### validateFormat

```nim
cs = cs.validateFormat("email", re".+@.+")
```

### validateInclusion

```nim
cs = cs.validateInclusion("age", 18..120)
```

### validateLength

```nim
cs = cs.validateLength("name", min = 2, max = 100)
```

### validateNumber

```nim
cs = cs.validateNumber("age", greaterThan = 0, lessThan = 150)
```

### validateConfirmation

Checks that two fields match (e.g. password confirmation):

```nim
cs = cs.validateConfirmation("password", "password_confirmation")
```

### validateExclusion

Ensures a field is not in a forbidden list:

```nim
cs = cs.validateExclusion("username", @["admin", "root", "system"])
```

## Checking Validity

```nim
if cs.isValid:
  let user = repo.insert!(cs)
else:
  echo cs.errors
  # {"name": @["can't be blank"], "email": @["has invalid format"]}
```

## Bang Methods

Repo bang methods (`insert!`, `update!`, `delete!`) raise `ValidationError` if the changeset is invalid:

```nim
let user = repo.insert!(cs)  # raises if cs.isInvalid
```

## Change Management

Beyond `castFields`, you can manipulate changes directly:

```nim
cs = cs.putChange("role", "admin")      # add/replace a change
cs = cs.forceChange("updated_at", now)  # bypass cast whitelist
cs = cs.deleteChange("temp_field")      # remove a change
```

Inspect changes:

```nim
echo cs.hasChange("name")      # true
echo cs.changedFields()        # @["name", "email"]
for field, value in cs.changes:
  echo field, " = ", value
```

Apply changes to the data object without writing to the database:

```nim
let updatedUser = cs.applyChanges()
```

## Batch Validation

When using `insert_all`, every changeset is validated before the batch query runs. If any changeset is invalid, `ValidationError` is raised immediately.

## Custom Validations

You can manually add errors:

```nim
proc validateCustom*[T](cs: Changeset[T]): Changeset[T] =
  result = cs
  if result.changes.hasKey("age"):
    let age = parseInt(result.changes["age"])
    if age < 18:
      result.addError("age", "must be at least 18")
```
