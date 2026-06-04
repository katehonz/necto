# Contributing to Necto

Thank you for your interest in making Necto better! This document provides guidelines for contributing to the project.

## Getting Started

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/necto.git
   cd necto
   ```
3. **Install dependencies**:
   ```bash
   nimble install -y
   ```

## Development Setup

Necto requires **Nim 2.0.0+** and **PostgreSQL 12+**.

### PostgreSQL

Create a local test database:

```bash
createdb necto_test
```

By default, tests expect:
- Host: `localhost`
- User: `postgres`
- Password: `pas+123`
- Database: `necto_test`

You can override these via environment variables:

```bash
export NECTO_HOST=localhost
export NECTO_USER=postgres
export NECTO_PASSWORD=yourpassword
export NECTO_DATABASE=necto_test
```

### Running Tests

```bash
# Run all tests (requires a running PostgreSQL instance)
nimble test

# Run migrations
nimble migrate

# Check migration status
nimble migrate_status
```

## Project Structure

```
necto/
├── src/
│   ├── necto.nim              # Public API entry point
│   └── necto/
│       ├── repo.nim           # Repository pattern, connection pool, CRUD
│       ├── schema.nim         # Schema macro, reflection, row loaders
│       ├── query.nim          # Query DSL, SQL builder
│       ├── changeset.nim      # Validation & casting
│       ├── migration.nim      # Migration DSL & registry
│       ├── migrator.nim       # Migration runner
│       ├── associations.nim   # Batch preload (N+1-safe)
│       ├── type_system.nim    # Nim ↔ PostgreSQL type mapping
│       ├── auth.nim           # Bcrypt + JWT helpers
│       ├── multi.nim          # Ecto.Multi-style transactions
│       └── adapters/
│           ├── base.nim       # Adapter interface
│           └── postgres.nim   # PostgreSQL adapter
├── tests/
│   ├── support/
│   │   └── test_repo.nim      # Test repo configuration
│   └── t_*.nim                # Test suites
├── docs/                      # Markdown documentation
├── benchmarks/                # Performance benchmarks
└── examples/                  # Example applications
```

## Coding Standards

- **Follow existing style**: 2-space indentation, snake_case for procs/vars, PascalCase for types.
- **Use `quoteIdentifier`** for all SQL identifier concatenation (table names, column names) to prevent injection.
- **Parameterize all values**: Never concatenate user input into SQL strings. Use `$1`, `$2` placeholders.
- **Write tests**: Every bug fix and new feature should include a test in `tests/`.
- **Keep macros simple**: Macros in `schema.nim` and `repo.nim` are powerful but can be hard to debug. Prefer compile-time procs where possible.
- **Document public APIs**: Use Nim doc comments (`##`) for all public procs, templates, and macros.

## Adding Tests

Tests use [Nim's built-in `testament` runner](https://nim-lang.org/docs/testament.html).

Example test file (`tests/t_your_feature.nim`):

```nim
import std/[unittest, tables]
import ../src/necto
import ../src/necto/adapters/postgres
import support/test_repo

necto_schema TestUser:
  table "test_users"
  field id: int64 {.primary_key, auto_increment.}
  field name: string {.not_null.}

suite "Your feature":
  test "does something useful":
    let cs = newChangeset(newTestUser(), {"name": "Alice"}.toTable)
      .castFields(@["name"])
      .validateRequired(@["name"])
    check(cs.isValid)
```

Run it with:

```bash
testament pattern tests/t_your_feature.nim
```

## Commit Messages

Use clear, descriptive commit messages:

- `feat: add window function support`
- `fix: resolve pool counter leak on connection release`
- `docs: update query DSL examples`
- `test: add coverage for soft delete edge cases`

## Pull Request Process

1. **Create a branch** for your changes:
   ```bash
   git checkout -b feat/my-feature
   ```

2. **Make your changes** and ensure tests pass:
   ```bash
   nimble test
   ```

3. **Update documentation** if you change public APIs (`README.md`, `docs/`, or inline doc comments).

4. **Push to your fork** and open a Pull Request against the `main` branch.

5. **Ensure CI passes**: Your PR must pass the GitHub Actions workflow before it can be merged.

## Reporting Issues

When reporting bugs, please include:

- **Nim version** (`nim -v`)
- **PostgreSQL version** (`psql --version`)
- **Minimal code example** that reproduces the issue
- **Expected behavior** vs **actual behavior**
- **Error messages** or stack traces

## Code of Conduct

Be respectful and constructive. We welcome contributors of all experience levels.

## Questions?

- Open a [GitHub Discussion](https://github.com/YOUR_USERNAME/necto/discussions)
- Check the [docs/](docs/) directory
- Read [ROADMAP.md](ROADMAP.md) for planned features
