# Running queries and mutations

`Sql.Query` and `Sql.Mutation` each run what they build: `fetch_one` /
`fetch_many` for reads, `execute` for writes. They live in the builder
modules rather than in `Sql` because that is where the row type is known —
a `Q(Selector(Patient))` fetches a `Patient` and nothing else.

`Sql` keeps the `*_raw` siblings, which take a `(String, List(Value))` pair
and cannot know what they return:

```jade
import Sql exposing (SqlError, execute_raw)
import Sql.Query exposing (fetch_many, fetch_one)
import Sql.Mutation exposing (execute)

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
Sql.Query.fetch_one    : Q(Selector(a))   -> Task(a, SqlError)
Sql.Mutation.fetch_one : Mutation(ret, c) -> Task(ret, SqlError)
```

A mutation only has a row type once `returning` gives it one, which is what
makes fetching from one meaningful.

For raw SQL, skip the builders: `fetch_one_raw` / `fetch_many_raw` /
`execute_raw` take a `(String, List(Value))` pair. Their result type is
unconstrained, which is honest — nothing about a hand-written string says
what it returns.

Row decoding is automatic — the caller's type (`Patient`, `List(Patient)`)
threads its `Decodable` instance into the polymorphic port. The runtime
returns plain Ruby hashes from AR, and they're decoded into typed structs
at the boundary.

`SqlError` variants:
- `DbError(String)` — AR `StatementInvalid` message
- `NotFound` — `fetch_one` with zero rows
- `NotUnique` — `fetch_one` with more than one row
- `Conflict(String)` — a write hit a unique index; the `String` is the
  violated constraint name (e.g. `users_email_key`), so you can route it to a
  field error instead of string-matching a `DbError` message

A decode mismatch (column type doesn't match the field type) raises on
the Ruby side rather than becoming a recoverable error — schema drift is
a programmer bug.

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
    all_calls_to(JadeSql::Runtime.port_execute_many) do |t, _sql, _params|
      t.ok([
        { "id" => 1, "name" => "Paul", "mrn" => "MRN-001" }
      ])
    end

    expect(MyApp.list.run).to be_ok
  end
end
```

The three ports are `port_execute_count`, `port_execute_one`,
`port_execute_many` — `Sql.execute*` / `Sql.fetch_*` and their `*_raw`
siblings ultimately dispatch through these. Stub them with
`all_calls_to(JadeSql::Runtime.port_execute_*) { |t, sql, params| ... }`.
