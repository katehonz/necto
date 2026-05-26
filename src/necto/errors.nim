## Necto Errors
##
## Йерархия от изключения, използвани от Necto.

type
  NectoError* = object of CatchableError
    ## Базово изключение за Necto.

  NotFoundError* = object of NectoError
    ## Вдигнато, когато очакваме точно един резултат, но няма такъв.

  ValidationError* = object of NectoError
    ## Вдигнато при невалиден changeset (ако използваме bang-методи).

  RollbackError* = object of NectoError
    ## Вдигнато при ръчен rollback в транзакция.

  QueryError* = object of NectoError
    ## Вдигнато при грешка в SQL заявка или невалиден query state.

  MigrationError* = object of NectoError
    ## Вдигнато при проблем с миграция.
