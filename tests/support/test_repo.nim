## Test Repo Setup
##
## Конфигурира тестов Repo за PostgreSQL:
##   host: localhost, user: postgres, password: pas+123, database: necto_test

import ../../src/necto
import ../../src/necto/adapters/postgres

necto_repo TestRepo:
  adapter PostgresAdapter
  host "localhost"
  port 5432
  user "postgres"
  password "pas+123"
  database "necto_test"
  pool_size 5
