# Running queries and writes

`fetch_one` / `fetch_many` live in `Sql.Query` and `Sql.Write`, because that
is where the row type is known — a `Select(Patient)` fetches a `Patient` and
nothing else. `Sql.execute` takes anything that renders, since a count says
nothing about the rows.

`Sql` keeps the `*_raw` siblings too, which take a `(String, List(Value))`
pair and cannot know what they return:

```jade
import Sql exposing (SqlError, execute, execute_raw)
import Sql.Query exposing (fetch_many, fetch_one)

# Affected count for INSERT/UPDATE/DELETE
def reschedule(a: Appointment) -> Task(Int, SqlError)
  a |> update(appointments) |> execute
end

# A single row, decoded into Patient
def find(id: Int) -> Task(Patient, SqlError)
  patient_by_id_query(id) |> fetch_one
end

# Many rows, decoded
def all -> Task(List(Patient), SqlError)
  all_patients_query |> fetch_many
end

# Raw SQL escape hatch — bypass the typed builders
def count_active -> Task(Int, SqlError)
  execute_raw(("SELECT COUNT(*) FROM patients WHERE archived = ?", [Encode.encode(False)]))
end
```

Each runner is typed against what its module builds, so the row type the
query was written to produce is the one it hands back:

```jade
Sql.Query.fetch_one    : Select(a)   -> Task(a, SqlError)
Sql.Write.fetch_one : Write(ret, c) -> Task(ret, SqlError)
```

A write only has a row type once `returning` gives it one, which is what
makes fetching from one meaningful.

Three reads have no row to decode, so they take a `Query` rather than a
`Select` and render their own select list over its clauses:

```jade
fetch_count  : Query(c)           -> Task(Int, e)      # SELECT COUNT(*)
fetch_exists : Query(c)           -> Task(Bool, e)     # SELECT EXISTS (…)
fetch_values : Query(c), Expr(b)  -> Task(List(b), e)  # one column, every row
```

`fetch_exists` stops at the first row Postgres finds rather than counting
every one of them. `exists` is the `Expr(Bool)` a `WHERE` takes, which is
where the keyword appears in SQL. `fetch_values` reads one column; for more
than one, `select |> field` names the shape they land in.

For raw SQL, skip the builders: `fetch_one_raw` / `fetch_many_raw` /
`execute_raw` take a `(String, List(Value))` pair. Their result type is
unconstrained, which is honest — nothing about a hand-written string says
what it returns.

A projection's rows come back as arrays, and each column goes through its
field type's `Decodable` in the position `field` put it. The `*_raw` runners
have no projection, so they decode by column name into the result type
instead.

`SqlError` variants:
- `NotFound` — `fetch_one` with zero rows
- `TooManyRows` — `fetch_one` with more than one row
- `UniqueViolation(String)` — a write hit a unique index; the `String` is the
  violated constraint name (e.g. `users_email_key`), so you can route it to a
  field error instead of string-matching a `DbError` message
- `ForeignKeyViolation(String)`, `CheckViolation(String)` and
  `ExclusionViolation(String)` — the same, for the other constraints
- `NotNullViolation(String)` — carries the column, since Postgres names no
  constraint for one
- `Deadlock` and `SerializationFailure` — the transaction lost; the statement
  is fine, and running it again is the usual answer
- `StatementTimeout` and `LockTimeout` — the statement ran out of time, or
  waiting for a lock did
- `DbError(String)` — anything else, as the adapter's message

A decode mismatch (column type doesn't match the field type) raises on
the Ruby side rather than becoming a recoverable error — schema drift is
a programmer bug.

## Coming from ActiveRecord

There is no `find` or `find_by`. A lookup is the predicate you meant and the
runner that says how many rows you expect — and for anything an index covers,
`matching` builds that predicate from the generated index:

```jade
from(patients)
  |> where(matching(patients_pkey, id))
  |> selected
  |> fetch_one
```

Which is `find_by!` — no row is `NotFound`. A primary key is generated as a
unique index like any other, so a lookup by id has the same shape as one by
email. The key type comes from the index, so a composite cannot be given in
the wrong order, and renaming the index in the DDL breaks the call rather
than quietly matching nothing. A hand-written `where`/`filter` predicate is
for the columns no index covers.

The one to watch is **`fetch_at_most_one`, which is not `find_by`**: `find_by` is `LIMIT 1` and
returns the first row it happens to get, where this errors with
`TooManyRows`, because nothing is dropped to make the type fit. A query
ported across compiles, passes review, and then fails in production on the
first row that has a twin. If you wanted `LIMIT 1`, say `limit(1)`.

**Errors are values, not exceptions.** A read hands back
`Task(a, SqlError)`, and at the Ruby boundary `["ok", value]` or
`["err", encoded]`. `Sql.unwrap!` turns that into the value or raises the
variant, so one `rescue_from` routes a missing row the way
`ActiveRecord::RecordNotFound` does:

```ruby
# app/controllers/application_controller.rb
rescue_from Sql::Errors::NotFound, with: :not_found

# and at the call site, on whatever your module exposes
patient = Sql.unwrap!(Patients.by_id(params[:id]))
```

The generated `fn!` raises too, but raises `Jade::Interop::TaskError` for
every failure alike, which a `rescue_from` cannot tell apart.

## Transactions

`Sql.transaction` runs a `Task` inside a single DB transaction on the
shared AR connection. Every `fetch_*` / `execute` the task performs
participates in it; the transaction commits on `Ok` and rolls back —
re-raising the error — on `Err`:

```jade
import Sql exposing (SqlError, execute, transaction)

def book(visit: NewVisit, patient: Patient) -> Task(Int, SqlError)
  record_visit(visit)
    |> Task.and_then((_) -> { touch_last_seen(patient) })
    |> transaction
end
```

Because the wrapped task keeps its own decoding, `transaction` is fully
polymorphic in the result — `transaction(t) : Task(a, SqlError)` for any
`t : Task(a, SqlError)`.

Transactions nest. A `transaction` inside another becomes a savepoint of
it, so an inner `Err` that the caller recovers from rolls back only the
inner work, while an outer `Err` still rolls back everything — including
what a nested transaction committed. The same holds in the other
direction: a jade transaction inside an `ActiveRecord::Base.transaction`
block is a savepoint of that block, and rolling the block back discards
the jade work with it.

Needs opt-in via `require 'jade-sql/runtime'`.

## Testing without a DB

The Task dispatcher can be stubbed. From RSpec:

```ruby
require 'jade/tasks/rspec'

describe MyApp do
  include Jade::Tasks::RSpec

  it 'queries patients' do
    all_calls_to(JadeSql::Runtime.port_execute_rows) do |t, _sql, _params|
      t.ok([[1, "Paul", "MRN-001"]])
    end

    expect(MyApp.list.run).to be_ok
  end
end
```

Everything dispatches through four ports. `port_execute_rows` runs the
builders' reads and RETURNING writes and answers with one array per row, in
`field` order. `port_execute_count` runs `execute`, and `port_execute_one` /
`port_execute_many` run the `*_raw` reads, answering with hashes keyed by
column name. Stub them with
`all_calls_to(JadeSql::Runtime.port_execute_*) { |t, sql, params| ... }`.
