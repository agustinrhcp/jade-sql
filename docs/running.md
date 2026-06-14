# Running queries and mutations

`Sql` exposes `fetch_one` / `fetch_many` for reads and `execute` for
writes — all polymorphic over anything `Renderable` (Q, Mutation, …) —
plus `*_raw` siblings that take a `(String, List(Value))` pair for the
escape hatch:

```jade
import Sql exposing (SqlError, execute, execute_raw, fetch_many, fetch_one)

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

`fetch_one` / `fetch_many` / `execute` accept anything that implements
`Sql.Renderable` (Q, Mutation). Internally they call `render(r) |> *_raw`,
where `render` is the interface method that resolves to each container's
`to_sql`. For raw SQL, skip the builder and call `fetch_one_raw` /
`fetch_many_raw` / `execute_raw` directly with a `(String, List(Value))`
pair.

Row decoding is automatic — the caller's type (`Patient`, `List(Patient)`)
threads its `Decodable` instance into the polymorphic port. The runtime
returns plain Ruby hashes from AR, and they're decoded into typed structs
at the boundary.

`SqlError` variants:
- `DbError(String)` — AR `StatementInvalid` message
- `NotFound` — `fetch_one` with zero rows
- `NotUnique` — `fetch_one` with more than one row

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

Transactions don't nest yet (no savepoints): wrapping a `transaction`
inside another issues a second `BEGIN` on the same connection. Needs
opt-in via `require 'jade-sql/runtime'`.

## Testing without a DB

The Task dispatcher can be stubbed. From RSpec:

```ruby
require 'jade/tasks/rspec'

describe MyApp do
  include Jade::Tasks::RSpec

  it 'queries patients' do
    all_calls_to(JadeSql::Runtime.port_execute_many) do |t, _pair|
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
`all_calls_to(JadeSql::Runtime.port_execute_*) { |t, pair| ... }`.
