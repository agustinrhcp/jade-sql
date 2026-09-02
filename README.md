# jade-sql

[![CI](https://github.com/agustinrhcp/jade-sql/actions/workflows/ci.yml/badge.svg)](https://github.com/agustinrhcp/jade-sql/actions/workflows/ci.yml)

Type-safe SQL for Jade. Builds queries and writes from a generated
schema, renders them to `(String, List(Value))`, and runs them against
ActiveRecord via a Task port that auto-decodes rows into typed Jade
structs.

## Install

```ruby
# Gemfile
gem 'jade-sql'
```

Its dependency, the `jade-lang` gem (the Jade compiler/runtime), resolves
from RubyGems automatically.

To execute queries at runtime, opt into the AR-backed task port:

```ruby
# config/initializers/jade_sql.rb (or similar)
require 'jade-sql/runtime'
```

To get the rake tasks for schema generation:

```ruby
# Rakefile (or lib/tasks/jade.rake)
load Gem.find_files('jade-sql/tasks.rake').first
```

`rake jade:schema` writes the schema; `rake jade:schema:check` fails when the
checked-in one no longer matches `db/structure.sql`, which is what a migration
merged without regenerating looks like. Both are also `jade-sql schema` and
`jade-sql schema --check`.

## At a glance

Generate a typed schema from `db/structure.sql`, then build a query against
it. The result is a `Query` you render with `to_sql` or run with `fetch_*`; rows
decode straight into your struct.

```jade
import Sql exposing (Selector, eq)
import Sql.Expr as Expr
import Sql.Query exposing (Query, field, from, join, select, where)
import Schema exposing (patients, appointments)

struct Visit = {
  name: String,
  reason: String
}

def scheduled_visits -> Query(Selector(Visit))
  p <- from(patients)
  a <- join(appointments, (a) -> { p.id |> Expr.eq(a.patient_id) })

  select(Visit(_, _))
    |> field(p.name)
    |> field(a.reason)
    |> where(a.status |> eq("scheduled"))
end
```

Run it with `scheduled_visits |> fetch_many` — a `Task(List(Visit), SqlError)`
that decodes each row into `Visit`.

## Documentation

- [Building SQL](docs/building.md) — generate a schema, build queries
  (joins, sorting/grouping, pagination, aggregates, arrays, JSONB) and
  writes (insert/update/delete, RETURNING, timestamps, UUIDs).
- [Running queries and writes](docs/running.md) — `fetch_*` / `execute`,
  transactions, and testing without a database.
