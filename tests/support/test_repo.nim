## Test Repo Setup
##
## Конфигурира тестов Repo за PostgreSQL.
## Стойностите могат да се променят чрез environment variables за CI:
##   NECTO_HOST, NECTO_USER, NECTO_PASSWORD, NECTO_DATABASE

import std/os
import ../../src/necto
import ../../src/necto/adapters/postgres

necto_repo TestRepo:
  adapter PostgresAdapter
  host getEnv("NECTO_HOST", "localhost")
  port 5432
  user getEnv("NECTO_USER", "postgres")
  password getEnv("NECTO_PASSWORD", "pas+123")
  database getEnv("NECTO_DATABASE", "necto_test")
  pool_size 5
