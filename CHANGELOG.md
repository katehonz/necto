# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Multi-database support**: MariaDB/MySQL and SQLite adapters alongside PostgreSQL.
  - `MariaDbAdapter` in `necto/adapters/mariadb` — connection pooling, `$N` → `?` translation, `LAST_INSERT_ID()` emulation.
  - `SqliteAdapter` in `necto/adapters/sqlite` — single shared connection with locking, `$N` → `?` translation, `last_insert_rowid()` emulation.
  - `SqlDialect` enum (`pdPostgres`, `pdMariaDb`, `pdSqlite`) with dialect-aware identifier quoting and type mapping.
  - Dialect-aware migration DDL generators (`createTable`, `dropTable`, `addColumn`, `renameColumn`, `modify`, etc.).
- Added `necto/adapters/common.nim` with shared utilities: `translatePlaceholders`, `SlowQueryTracker`, generic `runSelect`/`runExec`/`runScalar`/`runAffected` helpers.
- Added integration tests: `tests/t_mariadb.nim` (11 tests) and `tests/t_sqlite.nim` (12 tests).
- Added `nimble test_mariadb` and `nimble test_sqlite` tasks.
- Added `quoteIdentifier` proc to safely escape PostgreSQL identifiers (tables, columns) and prevent SQL injection via double-quote doubling.
- Added GitHub Actions CI workflow (`.github/workflows/ci.yml`) with PostgreSQL service container.
- Added `CHANGELOG.md` and `CONTRIBUTING.md`.

### Changed
- Bumped version in `necto.nimble` from `0.1.0` to `0.3.0` to reflect the implemented feature set.
- Updated `tests/support/test_repo.nim` to read database credentials from environment variables (`NECTO_HOST`, `NECTO_USER`, `NECTO_PASSWORD`, `NECTO_DATABASE`) for CI compatibility.
- Updated `PLAN.md` with a disclaimer pointing to `ROADMAP.md` and `docs/`, and fixed references to non-existent files (`query_builder.nim`, `query_dsl.nim`, `preloader.nim`).

### Fixed
- Fixed `querySql` placeholder replacement: replaced hardcoded `countdown(30, 1)` loop with a regex (`re"\\$\\d+"`) so queries with more than 30 placeholders no longer leak unresolved parameters.
- Replaced manual `"` concatenation for SQL identifiers with `quoteIdentifier(...)` across `repo.nim`, `query.nim`, `associations.nim`, and `migrator.nim`.
- Removed leftover compiled binaries from the working directory (not tracked by git, but occupying disk space).

## [0.3.0] - 2026-05-27

### Added
- **Subqueries & CTEs**: `whereIn` / `whereNotIn` with subqueries, `withCte` / `joinCte`, and `union` / `unionAll`.
- **Window functions**: `rowNumber`, `rank`, `denseRank`, `lag`, `lead` with `OVER` clause support.
- **Full-Text Search (FTS)**: `toTsVector`, `plaintoTsQuery`, `phrasetoTsQuery`, `websearchToTsQuery`, `toTsQuery`, `whereTsVectorMatches`, `orderByTsRank`, `orderByTsRankCd`.
- **Cursor-based streaming**: `streamAll` for memory-efficient iteration over large result sets.
- **Soft deletes**: `onlyDeleted`, `withDeleted`, `buildSoftDeleteSql`, and automatic `deleted_at IS NULL` filtering.
- **Migration locking**: Advisory locks (`pg_advisory_lock`) to prevent concurrent migration runs.
- **Multi-tenant support**: `queryTenantPrefix` for schema-qualified table names.
- **Query verification**: Runtime validation of queries against PostgreSQL via `EXPLAIN` and `information_schema`.

### Fixed
- Fixed prepared statement cache key collisions.
- Fixed `references` `onDelete` clause generation.
- Fixed CTE placeholder renumbering.
- Fixed migration reversal (`down` block auto-generation).
- Fixed pool counter leak on connection release.

## [0.2.0] - 2026-05-27

### Added
- **Schema verification**: Compile-time and runtime checks that Nim schemas match the PostgreSQL database.
- **Read replica support**: Separate read-only adapter with independent connection pool.
- **JSONB typed support**: `JsonB[T]` with compile-time JSON path access.
- **JSONB query operators**: `@>`, `?`, `?|`, `?&`, `#>>`, `#>`.
- **Zero-copy array loading**: Efficient deserialization of PostgreSQL arrays.
- **NectoType formal system**: `registerNectoType` convention for custom types.
- **PostgreSQL-specific types**: `PgPoint`, `PgTsVector`, `PgBox`, `PgCircle`, `PgLine`, `PgLseg`, `PgPath`, `PgPolygon`, `PgInterval`, `PgMoney`, `PgInt4Range`, `PgInt8Range`, `PgNumRange`, `PgTsRange`, `PgTsTzRange`, `PgDateRange`, `PgJson`, `PgJsonB`, `PgXml`, `PgBytea`, `PgMacAddr`, `PgMacAddr8`, `PgInet`, `PgCidr`, `PgBit`, `PgVarBit`, `PgUuid`, `PgOid`.
- **Benchmarks**: `benchmarks/necto_bench.nim` comparing ORM overhead against raw `db_postgres`.
- **Compiled query cache**: LRU cache for bound SQL strings.
- **Migration checksums**: MD5 checksum validation for safe rollback.

### Fixed
- Fixed `insert_all` column ordering bug.
- Fixed `whereDynamic` fragment argument passing.
- Fixed `updateSql` empty SET clause handling.
- Fixed constraint name parsing from PostgreSQL error messages.

## [0.1.0] - 2026-05-26

### Added
- **Core ORM skeleton**: `necto_schema`, `necto_repo`, Query DSL, Changeset, and Migration macros.
- **Repository pattern**: Connection pooling, transactions, savepoints, and constraint error mapping.
- **Query DSL**: `where`, `orWhere`, `whereDynamic`, `whereIt`, `select`, `orderBy`, `groupBy`, `having`, `limit`, `offset`, `join` (INNER, LEFT, RIGHT, FULL OUTER), `count`, `sum`, `avg`, `min`, `max`.
- **Changeset**: `castFields`, `validateRequired`, `validateFormat`, `validateInclusion`, `validateConfirmation`, `validateExclusion`, `unique_constraint`, `foreign_key_constraint`.
- **Migrations**: `change` block with auto-reversal, `up`/`down` blocks, CLI tools (`necto_migrate`, `necto_rollback`, `necto_status`, `necto_gen_migration`).
- **Associations**: `has_many`, `belongs_to`, `has_one`, `many_to_many` with N+1-safe batch preload.
- **Batch operations**: `insert_all`, `update_all`, `delete_all`.
- **Upserts**: `onConflictDoNothing` and `onConflictDoUpdate`.
- **Multi transactions**: `NectoMulti` for composable transaction steps.
- **Reverse schema generation**: `necto_gen_schema` to generate Nim schemas from existing PostgreSQL tables.
- **Pipe operator**: Elixir-style `|>` for query chaining.
- **27 test suites** covering repo, query, schema, types, associations, migrations, auth, and multi-tenancy.
