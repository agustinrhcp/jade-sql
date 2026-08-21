# Changelog

## [Unreleased]

Held unreleased on purpose: the accessor work and policies are breaking too,
and one migration is better than three.

### Added

- `Sql.transaction` nests. It becomes a savepoint of whichever transaction is
  already open, jade's or ActiveRecord's, so a recovered inner failure no
  longer discards the outer's work and a jade task inside an
  `ActiveRecord::Base.transaction` block no longer commits it early.
- `Pk(c)` and `pk_of`, and a generated `<table>_pk` per keyed table. The key
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
