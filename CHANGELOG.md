# Changelog

## [Unreleased]

Requires `jade-lang ~> 0.9.0`.

Held unreleased on purpose: the accessor work and policies are breaking too,
and one migration is better than three.

### Changed

- `MaybePatientsCols` is `PatientsLeftCols`, and `maybe_columns` is
  `left_columns`. Putting the modifier first split every table's vocabulary in
  two — sixty tables gave a block of `Maybe*` sorting away from the tables
  they belong to. The generated exposure list now reads down the table names.

- `Renderable` / `render` is `ToSql` / `to_sql`, which is what every module
  already called its own implementation of it. Two words for one operation,
  and the interface's was the one nobody typed.

- `now` is `db_now`. It renders `now()` for Postgres to evaluate, while
  `timestamped` and `stamped` write the app's clock — one word for two clocks
  in one library was a coin flip at every call site.

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

- `Sql.Mutation.stamped` wraps a value with `created_at`/`updated_at`, so the
  timestamps are written by the same argument the required-columns check
  reads: `insert(NewPatient("Ada") |> stamped, patients)`. `timestamped` still
  stamps a built `Mutation`, but a NOT NULL timestamp column is required of
  the value, and a pipe further down the chain cannot answer for it.

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
- `Sql.Query.filter` and `Sql.Mutation.filter` take a predicate as a function
  of the columns rather than a built one, which is what a caller that has not
  bound the columns needs.
- `Sql.strip_alias` is exposed: given a column accessor it recovers the column
  name from the `Expr`, so a scope needs the accessor alone rather than an
  accessor and a matching string.

### Fixed

- The transaction ports went through ActiveRecord's raw `begin_db_transaction`
  family, which only emits SQL. A second `BEGIN` on an open connection was a
  warning, and the matching `COMMIT` ended whichever transaction was already
  running.

### Breaking

- `Sql.fetch_one` and `Sql.fetch_many` are gone. They were polymorphic over
  anything `Renderable` with an **unconstrained result type**, so a
  `Q(Selector(Patient))` could be fetched as a `Task(Order, SqlError)` and it
  compiled. `Sql.Query.fetch_one` / `fetch_many` and `Sql.Mutation.fetch_one` /
  `fetch_many` / `execute` replace them, each typed against what its module
  builds. `Sql.execute` stays — its result is `Int`, so it had nothing to lose.
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
