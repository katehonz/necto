# Package
version       = "0.1.0"
author        = "Nim Community"
description   = "Ecto-inspired ORM for Nim with type-safe queries and changesets"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"

# Tasks
task test, "Run all test suites":
  exec "nimble test_postgres"

task test_postgres, "Run PostgreSQL tests":
  exec "testament pattern 'tests/t_*.nim'"
