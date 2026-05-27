# Necto Roadmap — Как да бием Ecto и Avram

> Версия: 1.0  
> Дата: 2026-05-26  
> Мото: *Не копираме Ecto. Използваме Nim, за да правим неща които Ecto никога няма да може.*

---

## Стратегия

Ecto е златен стандарт заради **10 години зрялост** и **BEAM concurrency**. Avram е отличен заради **Crystal type safety + удобство**. Нито един Nim ORM не е стигнал тяхното ниво — **това е нашият прозорец**.

Но няма да ги бием с "още един Ecto clone". Ще ги бием с **Nim superpowers**:

| Ecto слабост | Nim суперсила |
|-------------|---------------|
| Runtime overhead (BEAM процеси) | **Zero-cost абстракции** — компилираме до C, query DSL-ът е безплатен |
| Schema писане на ръка | **Compile-time reverse engineering** — генерираме schema от реална БД |
| JSONB полета са `map()` без типове | **Typed JSONB** — Nim тип системата сериализира/десериализира автоматично |
| Query грешки се хващат при пускане | **Compile-time SQL verification** — проверяваме таблици/колони при компилация |
| Deployment изисква Erlang/Elixir runtime | **Single binary** — ORM + app = 1 файл, zero dependencies |
| Memory pressure при големи preload-и | **ARC/ORC + value types** — по-ефективна памет от Crystal/Elixir |

---

## Фази

### 🔥 Фаза 1: DX Parity — "Удобен като Ecto" (Седмица 1–2)

Цел: Developer Experience трябва да е на нивото на Ecto/Avram. Без това никой няма да го пробва.

- [x] **1.1 Автоматичен `preload` в Query**  
  `repo.allWithPreload(Query.fromSchema(Post), "author")` — Repo автоматично прави 2-ра заявка и закача обектите.
- [x] **1.2 `preload` с множество асоциации**  
  `repo.allWithPreload(Query.fromSchema(Post), "author", "comments")` — оптимизирано (batch + reuse на connection).
- [x] **1.3 `whereIt` с пълни оператори**  
  `.whereIt(age > 18 and name == "Ivan")` — compile-time field check + operator overloading.
- [x] **1.4 `has_one` тестове и довършване**  
  Да работи както `belongs_to`/`has_many`.
- [x] **1.5 `insert_all` / `update_all` / `delete_all`**  
  Batch операции — `insert_all`, `update_all`, `delete_all` са готови и тествани.
- [x] **1.6 Advanced Changeset**  
  `put_change`, `force_change`, `delete_change`, `validate_confirmation`, `validate_exclusion`.
- [x] **1.7 `build_assoc` / `put_assoc` helpers**  
  `repo.build_assoc(post, "comments", %{"body" => "Nice"})`.
- [x] **1.8 Query pipelining + sugar**  
  `User |> fromSchema |> where("age", Gte, "18") |> repo.all` — Elixir-style pipe operator.

**Критерий за успех:** Примерното приложение `examples/friends` работи без ръчен preload и с pipe синтаксис.

---

### ⚡ Фаза 2: Nim Superpowers — "Невъзможно в Ecto" (Седмица 3–5)

Цел: Killer features, които са уникални за compile-to-native език с макроси.

- [x] **2.1 Compile-time schema verification (`necto_verify`)**  
  При компилация с `-d:nectoVerify` или `NECTO_VERIFY=1`, проверяваме:
  - Съществува ли таблицата?
  - Съвпадат ли колоните по име и тип?
  - Съществуват ли foreign key constraint-ите?
  Грешката спира програмата при стартиране (преди всякакви заявки).
  Добави `verify` statement в `necto_schema` блока за да активираш.
- [x] **2.2 Schema reverse engineering (`necto_gen_schema`)**  
  ```bash
  necto_gen_schema --table users --module MyApp.User
  ```
  Инспектира PostgreSQL `information_schema` и генерира:
  ```nim
  necto_schema User:
    table "users"
    field id: int64 {.primary_key, auto_increment.}
    field email: string {.not_null, unique.}
    # ...
  ```
- [ ] **2.3 Typed JSONB полета**  
  ```nim
  type UserSettings = object
    theme: string
    notifications: bool

  necto_schema User:
    field settings: JsonB[UserSettings]
  ```
  Автоматичен `jsonb_extract_path` + Nim типова сериализация. PostgreSQL пази JSONB, Nim вижда типизиран обект.
- [x] **2.4 Static query analysis**  
  `verifyQuery` template + startup-time EXPLAIN validation. Проверява:
  - Съществуване на таблица
  - Съществуване на всички колони (в WHERE, SELECT, ORDER BY, агрегати)
  - SQL синтаксис чрез PostgreSQL EXPLAIN (FORMAT JSON)
  Активира се с `-d:nectoVerify`.
- [x] **2.5 Zero-overhead benchmark suite**  
  Benchmark срещу raw db_postgres. Резултати (release build, 1000 rows):
  - PK lookup: ~25% overhead (type conversion + object construction)
  - INSERT: ~9% overhead (changeset validation + RETURNING)
  - COUNT: Necto is *faster* (prepared statement cache vs simple protocol)
  - SELECT 1000 rows: overhead from typed row loading (raw returns strings)
  Comparison vs Ecto/Avram planned for Phase 4.
- [x] **2.6 Compiled query cache**  
  `compileQuery()` pre-computes BoundQuery (SQL + args) once. Cache the result
  in a `let`. `querySql()` resolves all `$N` placeholders to NULL for EXPLAIN/debug.
  Combined with per-adapter prepared statement cache for zero re-computation.

**Критерий за успех:** Blog post "Necto: things Ecto can't do" с working examples за всяка точка.

---

### 🏭 Фаза 3: Production Ready — "По-добър от Norm за реални проекти" (Седмица 6–8)

Цел: Всичко нужно за production Nim приложения.

- [ ] **3.1 Prepared statement cache** (per connection)
- [ ] **3.2 Connection pool metrics** — wait time, active connections, queue depth (Prometheus формат)
- [ ] **3.3 Query timeout и slow query log**
- [ ] **3.4 Read replica support**  
  `repo.read()` → read replica, `repo.write()` → primary. Автоматично routing на `all` vs `insert`/`update`.
- [ ] **3.5 Transaction savepoints** — nested transactions
- [ ] **3.6 Full-text search helper** — PostgreSQL `tsvector`/`tsquery` DSL
- [ ] **3.7 Migration rollback с checksum валидация**
- [ ] **3.8 Soft deletes** — `field deleted_at: Option[DateTime]` + `.excludeDeleted()` query modifier
- [ ] **3.9 Multi-tenant support** — `schema_prefix` / `tenant_id` filtering
- [ ] **3.10 Streaming** — `repo.stream(Query)` iterator за големи резултати без `seq[T]` allocation

**Критерий за успех:** Пример production app с docker-compose (app + postgres + prometheus).

---

### 🌐 Фаза 4: Ecosystem & Adoption — "Стандартният Nim ORM" (Седмица 9–12)

Цел: Community, visibility, integration.

- [ ] **4.1 Интеграция с Karax** — форми генерират Changeset директно
- [ ] **4.2 Интеграция с Jester/Prologue/Mummy** — middleware за Repo context
- [ ] **4.3 Auth/Identity модул** — `necto_auth` с `User`, `Session`, `PasswordReset` schemas
- [ ] **4.4 Документация** — mkdocs с автоматично генериран API reference
- [ ] **4.5 Benchmarks публикувани** — сравнение с Ecto, Avram, Norm, Diesel, SQLx
- [ ] **4.6 nimble пакет** — `nimble install necto` работи перфектно
- [ ] **4.7 Video tutorials** — "Build a blog in 15 minutes with Necto"
- [ ] **4.8 Contribution guide и issue templates**

**Критерий за успех:** 100+ GitHub stars, 1+ external contributor, 1+ реален проект използва Necto.

---

## Тактика за изпълнение

### Седмичен ритъм
- **Понеделник:** Планиране + scope definition за седмицата.
- **Сряда:** Mid-week review — работи ли основното?
- **Петък:** Merge + test + документация. Нищо не се merge-ва без тест.

### Приоритет
1. **Тестове пред features.** Всяка нова функционалност = тест първо.
2. **PostgreSQL only.** Не пилеем време в MySQL/SQLite адаптери преди v1.0.
3. **Минимален код.** Nim макросите са мощни — ползваме ги за кратък, четим код.
4. **No breaking changes след 0.3.0.** До тогава API-то може да се движи.

---

## Метрики

| Метрика | Текущо | 0.3.0 | 0.4.0 | 1.0.0 |
|---------|--------|-------|-------|-------|
| Тестове | 3 suite, всички pass | 8 suite | 12 suite | 20+ suite |
| Редове код | ~3,400 | ~6,000 | ~10,000 | ~15,000 |
| Валидатори | 5 | 10 | 15 | 20+ |
| Query ops | 12 | 20 | 25 | 30+ |
| Време за compile (празен проект) | — | <2s | <2s | <3s |
| QPS vs ръчен SQL | 75-91% (measured) | >90% | >95% | >98% |

---

## Философия (не се променя)

- **No lazy loading.** Явен preload винаги.
- **No string interpolation в SQL.** Placeholders навсякъде.
- **Schema не знае за Repo.** Чисто разделение.
- **Zero runtime dependencies.** Само `db_connector` + stdlib.

---

*Ecto е вдъхновение, не цел. Нека Nim общността има ORM, който другите езици завиждат.*
