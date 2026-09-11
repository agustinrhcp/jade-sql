# Changelog

## [Unreleased]

### Breaking

- **`returning` means something else now. It is not a rename.** In 0.8 it took
  a projection; in 0.9 it takes nothing and derives the columns, and the
  projection-taking function is `returning_with`. Every 0.8 call site is
  therefore a 0.9 call site with the wrong arity — the compiler stops on all
  of them and none change behaviour silently — but read that as a meaning
  swap rather than a name moving, because the old name still compiles in your
  head. The short name went to the derived form because a projection the
  result type already describes is the overwhelming majority of what callers
  write; `returning_with` is for the row no result type can name.

### Changed

- **An unprojected read selects from the table whose columns the query
  carries.** `selected`, `fetch_row` and `fetch_rows` qualified every column
  with the first table the query named, while the query's type carried the
  columns of the last table it bound. After a join those were different
  tables, so `{ patient_id: Int }` read after `join(visits, …)` asked
  `patients` for it and failed at run time. The read now comes from the table
  the type names: after `join(visits, …)` or `left_join(visits, …)`, `visits`.
  A read that wants the first table's columns after a join names them with
  `select`.

### Added

- **`Write.returning` reads the RETURNING columns off the result type.**
  `Query.selected` has always derived a read's columns from the shape asked
  for; a write still needed a projection written by hand, so an app that
  inserts and reads back keeps a `project_q` per table only for that. The
  names go in unqualified, because RETURNING resolves against the one table
  the statement writes and there is nothing else in scope to disambiguate
  from.

      [assign("name", "Ada")]
        |> insert(patients)
        |> returning
      # INSERT INTO patients (name) VALUES (?) RETURNING id, name

  It stays a step of its own rather than something `fetch_one` does, which
  would take those call sites to zero. `Query` folds the two together in
  `fetch_rows` because `Query(c)` and `Select(a)` are different types, so no
  single value can render two statements; a `Write` is one type for both
  runners, and folding it in would mean `execute` and `fetch_one` producing
  different SQL from the same value.

### Fixed

- **An ActiveRecord block inside a jade transaction rolls back on its own.**
  The transaction let ActiveRecord join it, so a `raise ActiveRecord::Rollback`
  in an `ActiveRecord::Base.transaction` block run inside it was swallowed, and
  the block's writes committed with the jade transaction. It now opens as not
  joinable, and such a block takes a savepoint of its own.

- **Raw SQL runs one statement, whether or not it binds anything.** With no
  values to bind, ActiveRecord sends a statement over Postgres' simple query
  protocol, which runs every statement in the string, so an
  `Expr("…; DROP TABLE …", [])` or an `execute_raw` built from input ran all
  of them. A statement with nothing to bind and a `;` anywhere but at its end
  now raises `ArgumentError` before it reaches the database. A trailing `;`
  still runs.

## [0.8.0] - 2026-09-10

Requires `jade-lang ~> 0.10.0`.

Held back on purpose while the renames, the accessor work and the generator
fixes landed together, so an app crosses this once rather than three times.
Every name that moved is listed below; nothing here is a silent change.

The shortest migration: regenerate `schema.jd`, then follow the compiler.
Almost everything breaking is a rename it will point at, and the two that are
not — operators taking a value, and `set` taking a `Col` — fail to compile
rather than changing behaviour.

### Fixed

- **A write's predicate no longer loses its table.** The alias was stripped
  out of the finished WHERE, SET and RETURNING strings, subquery and all, so
  `patients.id` inside a correlated `NOT EXISTS` became a bare `id` that bound
  to the subquery's own table. Postgres plans that as a One-Time Filter, which
  empties the table or spares all of it, with no error either way. The target
  carries the alias its accessors were built with instead, and the surgery is
  gone.

- **A write with nothing to write says so.** An update whose assignments were
  all filtered out kept the caller's predicate and rendered a `SELECT`, which
  `exec_update` counts exactly as it counts an UPDATE — so it reported a row
  updated, took no lock, and a `returning` read handed back the row as it
  stood before. `insert_all([])` and `update_many([])` rendered invalid SQL.
  All three match nothing now and carry no parameters, so `execute` reports 0.
  A single row naming no columns is a row of defaults, `DEFAULT VALUES`.

- **A generated join predicate compiles.** `Sql.eq` takes a value; a join
  compares two columns. Every generated schema with a relation had failed to
  type check since the operators split. A relation named after a keyword —
  `import_id` gives `import` — made the module unparseable, and takes the same
  trailing underscore a reserved column gets.

- **The generator reads what pg_dump writes.** Identity columns in both
  spellings and as their own `ALTER`, generated columns, arrays carrying a
  length, and `citext` / `inet` / `cidr` / `macaddr`. An unknown type still
  stops the run: guessing buys a column that fails at decode instead of a
  message naming the DDL.

- **The generator says so when it cannot read its own output.** It used to
  hand back unformatted text and let the next compile find it, a build away
  from the DDL that caused it. Enum labels are sanitized with it — a label
  carrying a space was emitted verbatim and did not parse.

- **`jsonb_path_exists` can execute.** It rendered `@?`, and the runtime
  rewrites every `?` outside a quoted span into a placeholder, taking the
  operator's own with them. It renders the function Postgres provides, which
  holds no `?`. The other three `?`-spelled jsonb operators want the same
  treatment if they are ever added.

- **`update_many` is checked against the table it writes to.** The column
  check watched three of the write entry points; a derived `Assignable`
  compiled into any table this one was handed.

- **A nullable column is `Col(Maybe(T))` on the SET side too**, so clearing
  one back to NULL stops needing `execute_raw`.

- `from` twice in one bind chain rendered only the first table, while
  accessors for both were in scope and both were in the query's `tables`. The
  second table's columns reached the statement with nothing to resolve them
  against. Every table renders now, comma-separated, which is the cross join
  the value describes.

### Added

- **`ON CONFLICT`**, which is what `find_or_create_by`, `upsert` and
  `upsert_all` all compile to. `on_conflict` takes the target and an action —
  `do_nothing`, or `do_update` with what to write instead. The target is a
  generated `Unique`, so the index named is one the database has, and a
  primary key is generated as the unique index it is: `users_pkey` sits beside
  `users_email_key`.

- **`Sql.Json`**, for building a JSON document in Postgres rather than
  decoding rows that are about to become text again. Measured on an app:
  rendering a 100-row list endpoint spent 14.9ms, of which `JSON.generate` was
  0.064ms — the rest was per-row decode. The same response projected in SQL
  takes 0.15ms.

- **`Selectable`**, so a read whose result shape names the columns needs no
  `select`: `from(patients) |> fetch_rows`. The selection is qualified with
  the table the read is rooted in, since a bare column name on a join resolves
  to whichever table has one.

- **`val(v)`** puts a value where an expression is wanted — a constant field
  in a projection or a JSON document. The operators take values directly, so
  this is only for the positions that cannot.

- **Each enum is generated into a module of its own.** A Postgres enum belongs
  to the schema rather than to a table, and two enums sharing a label cannot
  sit in one module.

- `Sql.Query.subquery` renders a subquery in a value position,
  `(SELECT v.seen_on FROM visits v ... LIMIT 1)`. It takes the query and a
  function picking the column, since `Select(a)` says nothing about having
  exactly one and a subquery with two is a runtime error. The result is
  `Expr(Maybe(a))`: a subquery over no rows is NULL, same as `sum`.

- `Sql.Query.in_subquery` is the same shape for `col IN (SELECT ...)`. There
  is no `not_in`: `NOT IN` against a subquery yielding a NULL returns no rows
  at all, and `not_exists` is the form that does not have the trap.

- `Sql.Query.rows` is `select`'s unprojected twin, returning the columns
  rather than a projection. It is what lets a subquery be written in a bind
  chain, so `where`, `order_desc` and `limit` need no function forms of their
  own.
- `Sql.matching(users_email_key, key)` builds the predicate for a read by a
  unique index. `Unique(c, k)` carries the key type, so the wrong key does not
  compile and a composite cannot be given in the wrong order.

- `Sql.Query.fetch_at_most_one` is `fetch_one` with no row as an answer rather than
  an error. More than one is still `TooManyRows`: nothing is dropped to make
  the type fit.

- `Sql.Write.on_conflict_do_nothing` and `on_conflict_do_update` render
  `ON CONFLICT (cols) DO NOTHING` and `DO UPDATE SET ...`, which is what
  `find_or_create_by`, `upsert` and `upsert_all` all compile to. The conflict
  target is a `Unique` from the generated schema rather than a column list
  written out again, so it names an index the database has.
  `Sql.set_excluded(col)` is `col = EXCLUDED.col`, and `Sql.excluded(col)` is
  the proposed row's value as an ordinary `Expr`.

- The generator emits every unique index as a named `Unique(c)`, from both
  spellings: a table-level `UNIQUE (...)` and a standalone
  `CREATE UNIQUE INDEX`. Matching a
  `UniqueViolation` against `users_email_key.name` rather than a literal means
  renaming the index and regenerating breaks the call site instead of leaving
  it quietly never matching. Partial indexes are skipped, since they
  constrain only the rows their `WHERE` matches.

- `Sql.Query.exists` and `not_exists` render a correlated subquery as
  `EXISTS (SELECT 1 FROM …)`. They take an unprojected `Query`, since `EXISTS`
  ignores the select list, and the inner query may name the outer one's
  columns.

- `Sql.Query.having` filters on an aggregate after `group` has collapsed the
  rows, and `Sql.Query.distinct` renders `SELECT DISTINCT`. Both were on the
  list of clauses whose documented answer was dropping to `execute_raw` and
  hand-writing the whole statement.
- **`Selectable(a)`, the read side of `Assignable(a)`.** The shape you ask
  for names the columns, so a straightforward read needs no `select`:

  ```jade
  from(patients) |> fetch_row    -- SELECT id, name FROM patients
  ```

  Only the names are derived. Values decode through the port's own
  `Decodable(a)`, which already reads a row by field name, so a struct and an
  anonymous `{ name: String }` work the same way. `select` is untouched and
  stays the way to say anything computed: coalesce, an aggregate, an
  expression aliased to a field.

- The generator emits a type alias per table, so a function that takes one
  names it: `def archive(t: Patients)` rather than repeating
  `Table(PatientsCols, PatientsLeftCols, Int, NoJoins, RequiredPatientsCols)`.
  Nothing shorter is possible in general, since an alias has to bind every
  variable its body names; only a fully applied one saves anything.

- `Sql.Query.Select(a)` names `Query(Selector(a))`, so a finished query reads
  `-> Select(Visit)` rather than three type names to say one thing. `Selector`
  stays as the arity ledger `field` peels, but leaves application signatures.

- `within(col, range)` compares a column against a `Range`, so `a..b` renders
  as `BETWEEN ? AND ?` and the one-ended forms as `>=` / `<=`. An empty range
  is `FALSE` and an unbounded one `TRUE`, the way `any_of([])` is already
  `FALSE`.

### Added

- **`jade-sql schema --check`, and `rake jade:schema:check`.** The generator
  reads `db/structure.sql` and nothing else, so a schema that was not
  regenerated after a migration describes a database that no longer exists,
  and every type built on it is wrong in a way no compiler can see. The check
  regenerates in memory, compares, and names the tables that differ:

  ```
  schema.jd no longer matches the database:

    in the database, missing here: visits
    different: patients

  Regenerate it with `jade-sql schema`.
  ```

  It reports and stops there. Writing the migration that would close the gap
  needs the schema declared in jade, which is a separate piece of work.

### Changed

- Every operator takes the value on the right rather than an `Expr`, matching
  `any_of` and the jsonb functions, which already did: the six comparisons,
  `like`, `ilike`, `set`, `coalesce` and `array_concat`. `Sql.Expr` holds
  the eight comparisons again for the cases where the right side is something
  already built, such as another column or `db_now`, and `set_expr` does the
  same for an assignment built from the row.

- `to_expr` is gone rather than renamed. Every operator now encodes its own
  value, so nothing needed to wrap one by hand.

- `columns` and `left_columns` take only the table. The alias was a second,
  unchecked argument that had to match the one the table already carries, so
  the only thing it could add was a way to get it wrong. Use `aliased` to read
  a table under another name; it changes both halves at once.

- `set_` is `set` and `not_` is `not` — neither is a jade keyword, so the
  trailing underscore was never needed. `in_` is `any_of`, since `in` is one
  and no amount of renaming frees it.

- `Sql.Mutation` is `Sql.Write`, and `Mutation(ret, c)` is `Write(ret, c)`.
  The value is a description of a write not yet performed — immutable, in a
  language whose pitch is that nothing mutates — and the old name also
  collided with `Mutations::` in any app carrying a GraphQL layer.

- `Q(a)` is `Query(a)`. Every query function in an application carries the
  type in its signature, and a one-letter name is the one thing a reader
  cannot look up.

- `MaybePatientsCols` is `PatientsLeftCols`, and `maybe_columns` is
  `left_columns`. Putting the modifier first split every table's vocabulary in
  two — sixty tables gave a block of `Maybe*` sorting away from the tables
  they belong to. The generated exposure list now reads down the table names.

- `Renderable` / `render` is `ToSql` / `to_sql`, which is what every module
  already called its own implementation of it. Two words for one operation,
  and the interface's was the one nobody typed.

- `now` is `db_now`. It renders `now()` for Postgres to evaluate, while
  `timestamped` writes the app's clock — one word for two clocks in one
  library was a coin flip at every call site.

- `cast` is `unsafe_cast`. In Ecto, `cast/3` is the changeset function that
  converts and validates untrusted input; here it converts nothing and checks
  nothing, and a wrong one fails at decode time.

- `SqlError`'s `NotUnique` is `TooManyRows` and `Conflict` is
  `UniqueViolation`. The two were the wrong way round for anyone arriving from
  Rails or Ecto, where `RecordNotUnique` and `unique_constraint` are both the
  write-side index violation — here `NotUnique` was `fetch_one` seeing more
  than one row. `NotFound` and `TooManyRows` now read as the pair `fetch_one`
  returns.

### Added

- Each enum is generated into a module of its own, since a Postgres enum
  belongs to the schema rather than to a table — two tables can share one, and
  a table can have none. `invoice_status` becomes `Schema.InvoiceStatus`
  exposing `Status(..)`, so a database with an `invoice_status` and a
  `card_status` both carrying `pending` no longer produces a module that
  cannot compile. The type inside is named after the SQL type too, since every
  shorter name is a guess at where the SQL name divides;
  `jade.json` is where a better one gets said. `SchemaGenerator.generate`
  returns modules keyed by name, and `rake jade:schema` writes
  `schema/invoice_status.jd` next to `schema.jd`.

- `Table(c, m, k, o)` becomes `Table(c, m, k, o, r)`, where `r` is a struct of
  the columns an insert has to write, or `NoRequiredCols` for a table that has
  none. The generator works out which those are: NOT NULL, with no DEFAULT,
  identity or sequence behind them. `r` is phantom, so `table(...)` takes no
  new argument.

- Inserting a struct that leaves a required column unwritten is a compile
  error, naming the columns rather than letting Postgres reject the row at
  run time. `update` is untouched — the row it writes to already has them.

- `timestamped` wraps the value being written rather than the built write, so
  the required-columns check can see it: `insert(NewPatient("Ada") |>
  timestamped, patients)`. `update` writes only `updated_at`, dropping the
  `created_at` the wrapper added while keeping one the caller assigned.

- `neq`, `not_`, `like` and `ilike`.

- `Sql.transaction` nests. It becomes a savepoint of whichever transaction is
  already open, jade's or ActiveRecord's, so a recovered inner failure no
  longer discards the outer's work and a jade task inside an
  `ActiveRecord::Base.transaction` block no longer commits it early.
- `Pk(c)`, and a generated `<table>_pk` per keyed table. The key
  columns were already known to the generator, but only ever appeared as a
  bare `List(String)` inside the `table(...)` call, so nothing could name a
  table's key or check it against the table it belongs to. `Pk` is phantom in
  the column struct, which is the referent a foreign key needs — an FK
  references a key, not a bare column.
- `Sql.Query.filter` and `Sql.Write.filter` take a predicate as a function
  of the columns rather than a built one, which is what a caller that has not
  bound the columns needs.
- `Sql.strip_alias` is exposed: given a column accessor it recovers the column
  name from the `Expr`, so a scope needs the accessor alone rather than an
  accessor and a matching string.

### Fixed

- `set` recovered its column name by splitting the expression's rendered SQL on
  a dot, so `coalesce(c.nickname, "x") |> set("y")` produced an assignment to
  the column `nickname, ?)` and reached Postgres as `SET nickname, ?) = ?`. It
  now takes a `Col`, which carries the name, and the generator emits one record
  of them per table for `update_all` to hand to its builder. `strip_alias` is
  deleted rather than guarded.

- The transaction ports went through ActiveRecord's raw `begin_db_transaction`
  family, which only emits SQL. A second `BEGIN` on an open connection was a
  warning, and the matching `COMMIT` ended whichever transaction was already
  running.

### Breaking

- `Sql.fetch_one` and `Sql.fetch_many` are gone. They were polymorphic over
  anything `ToSql` with an **unconstrained result type**, so a
  `Query(Selector(Patient))` could be fetched as a `Task(Order, SqlError)`
  and it compiled. `Sql.Query.fetch_one` / `fetch_many` and
  `Sql.Write.fetch_one` / `fetch_many` / `execute` replace them, each typed
  against what its module builds. `Sql.execute` stays — its result is `Int`,
  so it had nothing to lose.
  The `*_raw` forms rows the free result type, which is honest: nothing about a
  hand-written string says what it returns.

- `Sql.SqlMapper` is now `Sql.Assignable`. The type implementing it is not a
  mapper, it is the thing being mapped, and the name now matches the `-able`
  interfaces around it.
- `Sql.Identified` is gone. It asked callers to re-state, positionally, values
  `to_assigns` already carried; `update` and `delete` now split those
  assignments by the table's primary key instead — key columns to the `WHERE`,
  in the order `structure.sql` declares them, and the rest to the `SET`.
- The struct you pass is the columns you write. `insert` writes every
  assignment, including the key, so a database-assigned key means inserting
  from a struct without that field.

To upgrade: rename the interface, and delete every `Identified` implementation
and its `pk_values` function.

### Breaking (typed keys)

- `pk_of` is gone: once the table carries a `Pk` rather than a `List(String)`
  it was `t.pk` spelled as a function.
- `Pk(c)` is now `Pk(c, k)`, carrying the key's type and a generated function
  that spreads a composite key across its columns in DDL order. `Table(c, m)`
  is `Table(c, m, k)` for the same reason: a write now takes a key, so the
  table has to say what one is. A table with no primary key is keyed by
  `NoKey`, which has no constructor callers can reach, so `update` and `delete`
  are unavailable on it — `update_all`/`delete_all` with a predicate are the
  only way to write to it.
- `update` and `delete` take the key as an argument rather than finding it
  among the assignments. Every write is now either keyed or scoped —
  `update`/`delete` take a key, `update_all`/`delete_all` take a predicate —
  so a struct with no key field can no longer render a `WHERE` that matches
  nothing and quietly report zero rows updated. A patch is a first-class
  thing: `Rename("Saul") |> update(patients, 42)`.
- `update_many` takes `List((k, a))`, threading each key into the JSON source
  rather than requiring every row struct to hold its own.

To upgrade: pass the key to `update` and `delete`, and regenerate `schema.jd`
— the generator's output changed, and a stale one has neither the `_pk` values
nor the new imports.

### Added (joins)

- Tables carry their foreign keys. The generator emits an `on` record per
  table with one join predicate per relation, and `Table(c, m, k)` becomes
  `Table(c, m, k, o)` to hold it. A join is written by naming the relation
  rather than by pairing two columns, so it cannot pair the wrong two, and
  nullable sides are lifted to match:

      p <- from(patients)
      a <- join(appointments, p |> patients.on.appointments)

  Each field takes the parent columns and returns the predicate `join` wants,
  which is a function of the joined table's columns alone. A table that
  declares no foreign keys gets `NoJoins`.

### Changed (compiler)

- The `Sql.Assignable` deriver moves out of jade and into this gem, registered
  through `Jade::Extensions`. Requires `jade-lang ~> 0.9.0`.
- A struct written to a table is checked against that table's columns, where
  the mapping was derived. A field with no column of its name, or one whose
  type is not the column's, is a compile error rather than invalid SQL.
