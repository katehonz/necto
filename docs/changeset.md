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
