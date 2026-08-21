# Building SQL

Generate a typed schema from your database, then build queries and
mutations against it. To run what you build, see [running.md](running.md).

## Generate `schema.jd` from `db/structure.sql`

```bash
bundle exec rake jade:schema
```

Reads `db/structure.sql`, writes `app/jade/schema.jd`. Knobs:

| ENV     | Default              | What                                      |
|---------|----------------------|-------------------------------------------|
| INPUT   | `db/structure.sql`   | source DDL file                           |
| OUTPUT  | `app/jade/schema.jd` | destination                               |
| TABLES  | (all)                | comma-separated whitelist                 |
| MODULE  | `Schema`             | module name in the generated file         |

Multiple schemas in one app (e.g. for gradual migration):

```bash
bundle exec rake jade:schema \
  TABLES=invoices,charges \
  MODULE=Schema.Billing \
  OUTPUT=app/jade/schema/billing.jd
```

Type map: `bigint`/`integer`/`smallint` → `Int`, `numeric`/`decimal` →
`Decimal` (jade's stdlib exact decimal), `double precision`/`real` →
`Float`, `varchar`/`text`/`char` → `String`, `boolean` → `Bool`,
`jsonb`/`json` → `Decode.Value`, `date` → `Calendar.Date`, `timestamp` →
`Clock.Instant`, `uuid` → `Uuid` (from `Sql.Uuid`). Unknown types fail
loudly with the table+column name.

`numeric`/`decimal` map to the stdlib `Decimal` — an exact base-10 value
(`coefficient * 10^exponent`), never `Float`, so no precision is lost.
Genuine floating-point columns (`double precision`/`real`) map to `Float`.
A `CREATE TYPE … AS ENUM` becomes a union, and its columns are typed by it:

```jade
-- CREATE TYPE visit_status AS ENUM ('scheduled', 'in_progress', 'done');

type VisitStatus
  = Scheduled
  | InProgress
  | Done
```

Nullary unions derive `Encodable` and `Decodable` with the variant name in
snake_case, which is the label Postgres stores — so the codec is free and
`eq(v.status, to_expr("schedulled"))` stops compiling. Before this, an enum
column failed generation outright with `Unknown SQL type`.

`bytea` isn't mapped yet, though jade's `Bytes` is the natural target. See
jade-lang's `Decimal` for the full API (`of`/`scaled`/`parse`, arithmetic,
`round`, `to_i`/`to_float`).

For each table, the generator emits:

```jade
struct PatientsCols      = { id: Expr(Int), name: Expr(String), ... }
struct MaybePatientsCols = { id: Expr(Maybe(Int)), name: Expr(Maybe(String)), ... }
struct PatientsRow       = { id: Int, name: String, ... }

def patients -> Table(PatientsCols, MaybePatientsCols)
  table("patients", "patients", ..., ["id"])
end

def patients_pk -> Pk(PatientsCols, Int)
  Pk(["id"], patients_pk_values)
end
```

Strict cols mirror NOT NULL constraints; the maybe version wraps every
field in `Maybe` for left-join projections. The default alias is the
table name; override per-call with `aliased` (see joins below).

`patients_pk` names the table's primary key. `Pk(c, k)` is phantom in the
column struct, so a key can only be used with the table it came from, and
carries the key's own type — `Int` here, a tuple for a composite key,
which a generated helper spreads across its columns in DDL order. A table
with no `PRIMARY KEY` in `structure.sql` gets no `_pk` and is keyed by
`NoKey`, which has no constructor you can reach — so `update` and `delete`
are unavailable on it, and `update_all`/`delete_all` are how you write to it.

Every foreign key in `structure.sql` becomes a field on the table's `on`
record, from both ends — one constraint, two ways to read it:

```jade
p  <- from(patients)
a  <- join(appointments, p |> patients.on.appointments)
ph <- left_join(phones, p |> patients.on.phone)
```

`join` never sees the left side — it builds a query the bind chain composes —
so the predicate it takes is a function of the joined table's columns alone.
Each field on the `on` record takes the parent columns and returns exactly
that, which is why the parent goes in by pipe and the child is left to `join`.

The result is an ordinary predicate function, the same thing a hand-written
`(ph) -> { ... }` is, so extra conditions compose:

```jade
ph <- left_join(phones, (ph) -> {
  ph |> (p |> patients.on.phone) |> and(ph.deleted_at |> is_null)
})
```

On a left join that distinction matters: the same condition in `where` would
drop the parent row instead of nulling the child.

An outgoing key is named after its column minus `_id`, an incoming one after
the table it comes from, and a second key between the same pair keeps its
column name to stay distinct. A nullable foreign key column is
`Expr(Maybe(a))` while the key it points at is `Expr(a)`, so the generated
predicate lifts whichever side is not nullable. A table with no foreign keys
carries `NoJoins`.

A column whose name is a Jade keyword (e.g. `type`) gets a trailing
underscore in the struct field (`type_`) while the SQL column reference
keeps the real name. For a table with such a column the generator also
emits a `<table>_row` projector that aliases every column to its field name
(`SELECT … AS type_`), so reads round-trip without hand-written SQL:

```jade
def entries -> Q(Selector(JournalEntriesRow))
  c <- from(journal_entries)
  journal_entries_row(c)
end
```

In hand-written selects, `field_as(e, "name")` sets a column's output name
when it differs from the SQL — needed for renamed columns and computed
projections (decode keys by field name, so `field_as(count_all, "visits")`
makes a `COUNT(*)` land in a `visits` field).

## Build queries

```jade
import Sql exposing (Selector, eq, to_expr)
import Sql.Query exposing (Q, field, from, join, select, where)
import Schema exposing (patients, appointments)

struct Visit = {
  name: String,
  reason: String
}

def scheduled_visits -> Q(Selector(Visit))
  p <- from(patients)
  a <- join(appointments, (a) -> { p.id |> eq(a.patient_id) })

  select(Visit(_, _))
    |> field(p.name)
    |> field(a.reason)
    |> where(a.status |> eq(to_expr("scheduled")))
end
```

Notes:
- `<-` is bind-chain — exposes each joined table's columns to the rest of
  the chain. `p` and `a` are the projected column accessors.
- `select(Visit(_, _))` uses placeholders. Each subsequent `field(...)`
  fills one slot in declared order.
- `to_sql(q)` returns `(String, List(Value))`.

### Predicates

`eq`, `gt`, `gte`, `lt`, `lte` compare two `Expr(a)` and yield `Expr(Bool)`;
`is_null` / `is_not_null` take one; `and` joins two; `in_` matches a list.
`now` is the DB clock (`now()`), for time comparisons:

```jade
import Sql exposing (column, gt, now, to_expr)

a.starts_at |> gte(to_expr(cutoff))          # a.starts_at >= ?
column("s", "expires_at") |> gt(now)         # s.expires_at > now()
```

`now` is `Expr(Instant)` — the *DB* transaction clock, not the app clock.
It's the right tool for `WHERE` filters; for `created_at`/`updated_at` use
`Sql.Mutation.timestamped` (below), which uses the app clock like Rails.

### Sorting and grouping

`order(q, e)` appends an ASC term, `order_desc(q, e)` a DESC term, and
`group(q, e)` a GROUP BY column. Repeated calls accumulate in declared
order — e.g. counting visits per patient, busiest first:

```jade
import Sql exposing (column, count_all)
import Sql.Query exposing (group, order, order_desc)

struct VisitCount = {
  name: String,
  visits: Int
}

def visit_counts -> Q(Selector(VisitCount))
  p <- from(patients)
  a <- join(appointments, (a) -> { p.id |> eq(a.patient_id) })

  select(VisitCount(_, _))
    |> field(p.name)
    |> field(count_all)
    |> group(column("p", "name"))
    |> order_desc(count_all)
    |> order(column("p", "name"))
end
# ... GROUP BY p.name ORDER BY COUNT(*) DESC, p.name
```

`HAVING` and `CASE` aren't built in yet — for filtering aggregates or
conditional expressions, fall back to the raw-SQL escape hatch
(`execute_*`). Basic aggregates (`SUM`, `COUNT`) and the
null-handling primitive (`coalesce`) are typed; see *Aggregates,
COALESCE* below.

### Pagination

`limit(q, n)` and `offset(q, n)` append `LIMIT`/`OFFSET` clauses. Both
take a plain `Int` and render inline (not as parameters), so the
returned `List(Value)` is unaffected:

```jade
import Sql.Query exposing(limit, offset)

def page(n: Int) -> Q(Selector(Visit))
  scheduled_visits
    |> limit(20)
    |> offset(n * 20)
end
```

Calling `limit`/`offset` more than once overrides the previous value
(last call wins).

### Walking a big result

`in_batches` runs a query a page at a time, handing each page to a step and
starting the next page only once that page's `Task` has finished, so nothing
holds more than `size` rows. It answers how many rows it saw. `find_each` is
the same thing with the step running per row.

```jade
import Sql.Query exposing(find_each, in_batches, order)

def archive_all -> Task(Int, SqlError)
  old_visits |> in_batches(1000, archive)
end


def notify_all -> Task(Int, SqlError)
  old_visits |> find_each(1000, notify)
end
```

Paging is LIMIT/OFFSET, so the query needs an `order` on something unique.
Without one Postgres may return rows in a different order per page, and a row
can be seen twice or missed entirely — nothing enforces this yet.

### Self-joins

The schema's default alias = table name. Override with `aliased`:

```jade
p <- from(patients)
c <- patients |> aliased("c") |> join((c) -> { p.id |> eq(c.parent_id) })
```

### Left joins with nullable views

`left_join` switches the joined table to its maybe-column view:

```jade
p <- from(patients)
a <- left_join(appointments, (a) -> { p.id |> eq(a.patient_id) })
# `a` is MaybeAppointmentsCols; field types are Expr(Maybe(String)) etc.
```

For predicates that lift a non-null column into the nullable side,
`nullable`:

```jade
p.id |> nullable |> eq(a.patient_id)  # Expr(Int) → Expr(Maybe(Int))
```

### Phantom-type rewrap with `cast`

`cast(e: Expr(a)) -> Expr(b)` widens a column's phantom type — useful
for projecting a `VARCHAR` column into a typed enum field whose
`Decodable(b)` instance does the actual parsing at row decode:

```jade
struct Appointment = { id: Int, status: Status, ... }

# status column is VARCHAR; Status has a Decodable(Status) impl that parses
# "scheduled" / "completed" into the variants.
select(Appointment(_, _, ...))
  |> field(a.id)
  |> field(a.status |> cast)   # Expr(String) → Expr(Status)
```

Same shape as `nullable` — pure phantom-type rewrap, no runtime
transformation. The runtime decoder (`Decodable(Status)`) is what
actually converts the column value; `cast` just teaches the SQL
builder that the projection is intended. If `Decodable(b)` can't
parse the column's actual values, the failure surfaces at row
decode time, not at type check.

### Aggregates, COALESCE

A small typed surface for SQL functions that would otherwise force you
into hand-built `Expr` strings. All compose with the rest of the
builder — params stitch in declaration order automatically.

| Function                                       | SQL                | Notes                                  |
|------------------------------------------------|--------------------|----------------------------------------|
| `sum(Expr(Int)) -> Expr(Maybe(Int))`           | `SUM(e)`           | `NULL` on empty group → `Maybe`.       |
| `count(Expr(a)) -> Expr(Int)`                  | `COUNT(e)`         | Counts non-null rows for the column.   |
| `count_all -> Expr(Int)`                       | `COUNT(*)`         | Total row count.                       |
| `coalesce(Expr(Maybe(a)), Expr(a)) -> Expr(a)` | `COALESCE(e, def)` | Drops the `Maybe` with a fallback.     |
| `neg(Expr(Int)) -> Expr(Int)`                  | `-(e)`             | Unary minus.                           |

Worked example — count visits and the most recent visit number,
coalesced to 0 when a patient has none:

```jade
import Sql exposing (coalesce, column, count_all, sum, to_expr)

select(Totals(_, _))
  |> field(count_all)
  |> field(coalesce(sum(column("a", "visit_no")), to_expr(0)))
# SELECT COUNT(*), COALESCE(SUM(a.visit_no), ?)
```

For `CASE WHEN`, `HAVING`, and arithmetic, fall back to the raw-`Expr`
escape hatch until they get a typed builder.

### Postgres arrays

Typed predicates on `text[]` / `int[]` / `uuid[]` columns. All bind
the array as a single param (`$1`) — `pg` maps Ruby `Array` to a PG
array natively, and PG infers the element type from the column on
the other side of the operator. No `ARRAY[$1,...,$N]` expansion, no
`ARRAY[]::t[]` cast needed for empty inputs.

| Function                                                       | SQL                          |
|----------------------------------------------------------------|------------------------------|
| `array_overlaps(Expr(List(a)), List(a)) -> Expr(Bool)`         | `col && ?` (any-of)          |
| `array_has(Expr(List(a)), a) -> Expr(Bool)`                    | `? = ANY(col)` (membership)  |
| `array_contains(Expr(List(a)), List(a)) -> Expr(Bool)`         | `col @> ?` (all-of)          |
| `array_contained_by(Expr(List(a)), List(a)) -> Expr(Bool)`     | `col <@ ?` (subset)          |
| `array_length(Expr(List(a))) -> Expr(Int)`                     | `cardinality(col)`           |

Example — filter appointments whose tag set overlaps any selected chip:

```jade
import Sql exposing (array_overlaps, column)

def filter_by_tags(selected: List(String)) -> Expr(Bool)
  array_overlaps(column("a", "tags"), selected)
end
# WHERE a.tags && ?    (param: ["urgent","followup"])
```

`array_length` uses `cardinality(col)` rather than Postgres'
`array_length(col, 1)` because `cardinality` is non-null (returns 0
on empty). Filter untagged rows with
`array_length(column("a", "tags")) |> eq(to_expr(0))`.

Mutation ops for partial array updates:

| Function                                                            | SQL                          |
|---------------------------------------------------------------------|------------------------------|
| `array_append(Expr(List(a)), a) -> Expr(List(a))`                   | `array_append(col, ?)`       |
| `array_remove(Expr(List(a)), a) -> Expr(List(a))`                   | `array_remove(col, ?)`       |
| `array_concat(Expr(List(a)), Expr(List(a))) -> Expr(List(a))`       | `left ‖ right`               |

Use these in `update_all` to avoid rewriting an array column wholesale:

```jade
appointments
  |> update_all(
       (a) -> { a.id |> eq(to_expr(aid)) },
       (a) -> { [a.tags |> set_(array_append(a.tags, new_tag))] },
     )
# UPDATE appointments SET tags = array_append(tags, ?) WHERE id = ?
```

Out of scope: `unnest`, `array_agg`. Add when a caller hits them.

### JSONB predicates

| Function                                                  | SQL                |
|-----------------------------------------------------------|--------------------|
| `jsonb_contains(Expr(Value), a) -> Expr(Bool)`            | `col @> ?`         |
| `jsonb_path_exists(Expr(Value), String) -> Expr(Bool)`    | `col @? ?::jsonpath` |

`jsonb_contains` auto-encodes the value via its `Encodable` instance,
so you can pass any record / scalar / list directly:

```jade
import Sql exposing (column, jsonb_contains, jsonb_path_exists)

struct KindMatch = { kind: String }

# WHERE r.meta @> ?       (param: { "kind": "referral" })
def matches_kind(k: String) -> Expr(Bool)
  jsonb_contains(column("r", "meta"), KindMatch(k))
end

# WHERE r.meta @? ?::jsonpath   (param: "$.priority ? (@ > 1)")
def has_priority_gt(path: String) -> Expr(Bool)
  jsonb_path_exists(column("r", "meta"), path)
end
```

The `@?` operator requires `jsonpath` on the right; the param binds as
text and gets cast at the SQL level.

## Build mutations

One interface says which columns a value writes:

```jade
import Sql exposing(Assignment, Assignable, assign)

struct Patient = { id: Int, name: String, mrn: String }

implements Assignable(Patient) with
  to_assigns: encode_patient
end

def encode_patient(p: Patient) -> List(Assignment)
  [
    assign("id",   p.id),
    assign("name", p.name),
    assign("mrn",  p.mrn)
  ]
end
```

`Assignable` derives for any struct, so the `implements` block above is
only needed when you want something other than one column per field.

**The struct you pass is the columns you write.** `insert` writes every
assignment. `update` and `delete` take the key as an argument, so what you
write and which row you write it to stay separate:

```jade
struct NewPatient = { name: String, mrn: String }

struct Rename = { name: String }

NewPatient("Ada", "MRN-1") |> insert(patients)   # INSERT (name, mrn)
Rename("Ada") |> update(patients, 7)             # SET name WHERE id = 7
delete(patients, 7)                              # DELETE WHERE id = 7
```

A patch needs no key field of its own, and a struct that does carry one —
a whole row — has it stripped from the `SET`. Every write is either keyed
or scoped: `update` and `delete` take a key, `update_all` and `delete_all`
take a predicate, and there is no third form to land in with neither.

The key is a `k`, never a column name and never an order, so a composite
key cannot be listed the wrong way round — the generated values function
spreads it across its columns as `structure.sql` declares them.

`assign(col, value)` is shorthand for
`Assignment(col, "?", [encode(value)])`. For non-`?` placeholders
(e.g. `"visit_no + ?"` for increments) use the `Assignment(...)`
constructor directly.

Then the mutation API works on values directly:

```jade
import Sql.Mutation exposing(insert, update, delete, insert_all, update_all, delete_all, to_sql)

p |> insert(patients) |> to_sql        # INSERT INTO patients (name, mrn) VALUES (?, ?)
p |> update(patients) |> to_sql        # UPDATE patients SET name = ?, mrn = ? WHERE id = ?
p |> delete(patients) |> to_sql        # DELETE FROM patients WHERE id = ?

[p1, p2] |> insert_all(patients) |> to_sql

appointments
|> update_all((a) -> { a.status |> eq(to_expr("scheduled")) },
              (a) -> { [a.cancelled |> set_(to_expr(True))] })
|> to_sql

appointments
|> delete_all((a) -> { a.cancelled |> eq(to_expr(True)) })
|> to_sql
```

### RETURNING

`returning` is the mutation-side counterpart to `select` for queries.
It takes a closure that receives the table's column accessors and
builds a Q-wrapped selector projecting them into a target type. The
Q wrapper is just to share the same `select`/`field` builders as
queries — `returning` extracts the inner `Selector` and discards the
empty Q state.

```jade
import Sql exposing(Selector)
import Sql.Query exposing(select, field)
import Sql.Mutation exposing(insert, returning, to_sql)

# INSERT INTO patients (name, mrn) VALUES (?, ?) RETURNING id, name, mrn
np
|> insert(patients)
|> returning((p) -> {
  select(Patient(_, _, _))
  |> field(p.id)
  |> field(p.name)
  |> field(p.mrn)
})
|> to_sql                    # or |> fetch_one to run
```

Bonus: the projector can be defined once and shared between SELECT
queries and RETURNING — both contexts now take the same `cols ->
Q(Selector(target))` shape, so a single `def patient_projector(p)`
works for `from(patients) |> patient_projector` (query) and
`... |> returning(patient_projector)` (RETURNING).

Combined with `Sql.fetch_one`, the inserted row decodes into the
target struct:

```jade
def create(np: NewPatient) -> Task(Patient, SqlError)
  np |> insert(patients) |> returning((p) -> {
    select(Patient(_, _, _))
    |> field(p.id)
    |> field(p.name)
    |> field(p.mrn)
  })
  |> fetch_one
end
```

`filter` narrows a query or a mutation you have already built. Where
`where` takes a predicate, `filter` takes a *function* of the columns, so a
caller that has not bound them can still add one — enough to write a
tenancy wrapper that scopes a keyed write, rather than funnelling every
scoped write through the `_all` forms.

`insert` / `insert_all` / `update` / `delete` need `Assignable(a)`, and
nothing else. `update_all`/`delete_all` build the SET / WHERE clauses
directly from the column accessors — no codec.

`Assignable` is also implemented for `List(Assignment)` itself, so you
can pass an assignment list to `insert` directly when you've already
built it (e.g. from a sparse changeset):

```jade
sparse_changes
|> List.and_then(field_to_assigns)
|> insert(_, patients)
```

### Timestamps

`insert`/`update` emit only the columns you set — they don't auto-fill
`created_at` / `updated_at`. Opt in per-write with `timestamped`, which
works like ActiveRecord: `created_at` + `updated_at` on insert, `updated_at`
only on update.

```jade
import Sql.Mutation exposing (insert, timestamped, update)

new_patient |> insert(patients) |> timestamped |> execute   -- both set
patient     |> update(patients) |> timestamped |> execute   -- updated_at only
new_import  |> insert(patients) |> execute                  -- no timestamps
```

It's opt-in on purpose — backfills, imports, and `touch: false`-style writes
just omit it (and can set the columns explicitly). The value is the **app
clock** at execute time (set in Ruby, the same clock Rails uses, so
`travel_to`/Timecop freeze it), and `created_at` == `updated_at` on an
insert. No schema changes and no DB-side `DEFAULT` needed.

### UUIDs

`Sql.Uuid` defines an opaque `Uuid` type plus generation/parse helpers.
The schema generator emits `Uuid` for `uuid` columns:

```jade
import Sql.Uuid exposing (Uuid, v4, v7, parse, to_string)

# DB-side generation (recommended for PKs):
# ALTER TABLE patients ALTER COLUMN id SET DEFAULT gen_random_uuid();

# App-side generation (idempotency keys, child-row pre-linking, …):
def make_request_id -> Task(Uuid, Never)
  v7    # time-ordered, friendlier to DB index locality than v4
end
```

`v4` and `v7` are zero-arg Tasks (`def v4 -> Task(Uuid, Never)`); call
them without parens. `parse(String) -> Maybe(Uuid)` accepts the
canonical 8-4-4-4-12 form (case-insensitive, stored lowercase).
`to_string(Uuid) -> String` for the canonical text form.

`Encodable(Uuid)` and `Decodable(Uuid)` impls are in the module, so
Uuids flow through SQL params, RETURNING decoding, and JSON boundaries
without extra wiring.

#### Short (Base64) display form

The canonical 36-char form is too noisy for URLs / admin UIs / logs.
`to_b64` / `from_b64` round-trip a Uuid through 22-char url-safe
Base64 (no padding), preserving the v7 time-ordering:

```jade
import Sql.Uuid exposing (to_b64, from_b64)

to_b64(u)                              # "VQ6EAOKbQdSnFkRmVUQAAA"
from_b64("VQ6EAOKbQdSnFkRmVUQAAA")     # Just(u)
from_b64("nope")                       # Nothing
```

`from_b64` returns `Nothing` for non-base64 input or for valid base64
that decodes to a length other than 16 bytes.
