## Necto — Ecto-inspired ORM for Nim
##
## Основен entry point. Импортира всички публични модули.
## Adapter-ите се импортират conditional — всеки изисква съответната native библиотека при линкване.

import necto/[repo, schema, query, changeset, type_system, associations, errors, migration, migrator, schema_generator, schema_verifier, query_verifier, multi]
import necto/adapters/postgres
export repo, schema, query, changeset, type_system, associations, errors, migration, migrator, schema_generator, schema_verifier, query_verifier, multi
export postgres

when defined(nectoMariadb) or defined(nectoFull):
  import necto/adapters/mariadb
  export mariadb

when defined(nectoSqlite) or defined(nectoFull):
  import necto/adapters/sqlite
  export sqlite
