# Changelog

## [Unreleased]

Requires `jade-lang ~> 0.10.0`.

Held unreleased on purpose: the accessor work and policies are breaking too,
and one migration is better than three.

### Fixed

- `from` twice in one bind chain rendered only the first table, while
  accessors for both were in scope and both were in the query's `tables`. The
  second table's columns reached the statement with nothing to resolve them
  against. Every table renders now, comma-separated, which is the cross join
  the value describes.

### Added

- `Sql.Query.having` filters on an aggregate after `group` has collapsed the
  rows, and `Sql.Query.distinct` renders `SELECT DISTINCT`. Both were on the
  list of clauses whose documented answer was dropping to `execute_raw` and
  hand-writing the whole statement.

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
  The `*_raw` forms keep the free result type, which is honest: nothing about a
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
