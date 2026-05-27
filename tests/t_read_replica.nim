## Тест за read replica support (compile-time конфигурация)

import std/[unittest]
import ../src/necto
import ../src/necto/adapters/postgres

necto_repo ReplicaTestRepo:
  adapter PostgresAdapter
  host "master.host"
  port 5432
  user "postgres"
  password "secret"
  database "myapp"
  pool_size 10
  read_host "replica.host"
  read_port 5433
  read_pool_size 5

necto_repo SimpleRepo:
  adapter PostgresAdapter
  host "localhost"
  user "postgres"
  password "secret"
  database "myapp"

suite "Read replica configuration":
  test "Repo has readAdapter when read_host is configured":
    let repo = newReplicaTestRepo()
    check(repo.adapter != nil)
    check(repo.readAdapter != nil)
    check(repo.readAdapter != repo.adapter)

  test "Master and replica have different hosts":
    let repo = newReplicaTestRepo()
    let master = PostgresAdapter(repo.adapter)
    let replica = PostgresAdapter(repo.readAdapter)
    check(master.host == "master.host")
    check(replica.host == "replica.host")
    check(master.port == 5432)
    check(replica.port == 5433)
    check(master.poolSize == 10)
    check(replica.poolSize == 5)

  test "Repo without read_host uses same adapter for reads":
    let repo = newSimpleRepo()
    check(repo.adapter != nil)
    check(repo.readAdapter == repo.adapter)
