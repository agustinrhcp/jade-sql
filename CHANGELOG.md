# Changelog

## [0.8.0]

Requires `jade-lang ~> 0.8.0`, which is where `Sql.Assignable` is derived.

### Breaking

- `Sql.SqlMapper` is now `Sql.Assignable`. The type implementing it is not a
  mapper, it is the thing being mapped, and the name now matches the `-able`
  interfaces around it.
- `Sql.Identified` is gone. It asked callers to re-state, positionally, values
  `to_assigns` already carried; `update` and `delete` now split those
  assignments by the table's primary key instead — key columns to the `WHERE`,
  in the order `structure.sql` declares them, and the rest to the `SET`.
- The struct you pass is the columns you write. `insert` writes every
  assignment, including the key, so a database-assigned key means either
  inserting from a struct without that field or taking one from `next_id`.

To upgrade: rename the interface, delete every `Identified` implementation and
its `pk_values` function, and regenerate `schema.jd` — the generator's output
changed, and a stale one has neither the `_pk` values nor the new imports.

### Added

- `Sql.transaction` nests. It becomes a savepoint of whichever transaction is
  already open, jade's or ActiveRecord's, so a recovered inner failure no
  longer discards the outer's work and a jade task inside an
  `ActiveRecord::Base.transaction` block no longer commits it early.
- `Sql.next_id` reads the next value off a table's key sequence, so a row is
  complete before it is inserted. Polymorphic in the key; needs a
  single-column primary key.
- `Pk(c)` and `pk_of`, and a generated `<table>_pk` per keyed table — a key
  that can only be used with the table it came from.

### Fixed

- The transaction ports went through ActiveRecord's raw `begin_db_transaction`
  family, which only emits SQL. A second `BEGIN` on an open connection was a
  warning, and the matching `COMMIT` ended whichever transaction was already
  running.
