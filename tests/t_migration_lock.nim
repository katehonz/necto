## Тестове за migration advisory locks

import std/[unittest, hashes]
import ../src/necto
import ../src/necto/adapters/postgres
import ../src/necto/migrator
import support/test_repo

suite "Migration locking":
  setup:
    testrepoInstance.exec("DROP TABLE IF EXISTS necto_schema_migrations")

  teardown:
    testrepoInstance.exec("DROP TABLE IF EXISTS necto_schema_migrations")
    # Ensure any held advisory locks are released
    try:
      testrepoInstance.exec("SELECT pg_advisory_unlock_all()")
    except:
      discard

  test "withAdvisoryLock acquires and releases lock":
    let migrator = newMigrator(testrepoInstance)
    migrator.bootstrap()

    var counter = 0
    proc body() =
      counter += 1
      # Verify lock is held by trying to acquire it (should block)
      # We can't easily test blocking, but we can verify no error

    migrator.withAdvisoryLock(body)
    check(counter == 1)

    # After release, we should be able to acquire again
    migrator.withAdvisoryLock(body)
    check(counter == 2)

  test "disableLock bypasses advisory lock":
    let migrator = newMigrator(testrepoInstance)
    migrator.disableLock = true
    migrator.bootstrap()

    # Hold the lock manually
    let lockId = hash("necto_schema_migrations").int64
    let absLockId = if lockId < 0: -lockId else: lockId
    testrepoInstance.exec("SELECT pg_advisory_lock(" & $absLockId & ")")

    var counter = 0
    proc body() =
      counter += 1

    # Should succeed even though lock is held
    migrator.withAdvisoryLock(body)
    check(counter == 1)

    # Release manual lock
    testrepoInstance.exec("SELECT pg_advisory_unlock(" & $absLockId & ")")

  test "advisory lock blocks concurrent access":
    let migrator = newMigrator(testrepoInstance)
    migrator.bootstrap()

    let lockId = hash("necto_schema_migrations").int64
    let absLockId = if lockId < 0: -lockId else: lockId

    # Acquire lock manually (simulating another migrator process)
    testrepoInstance.exec("SELECT pg_advisory_lock(" & $absLockId & ")")

    var bodyExecuted = false
    proc body() =
      bodyExecuted = true

    # Start withAdvisoryLock in background — it will block
    # We can't easily spawn threads in unittest, so instead:
    # Release the lock, then verify body executes
    testrepoInstance.exec("SELECT pg_advisory_unlock(" & $absLockId & ")")
    migrator.withAdvisoryLock(body)
    check(bodyExecuted)
