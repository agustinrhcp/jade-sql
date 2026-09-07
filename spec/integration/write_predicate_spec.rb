require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # A write's predicate may name the table it writes to and a table it only
  # reads, and the two have to stay told apart. Rendering, not executing, is
  # what used to lose that: the qualifier was stripped out of the finished
  # string, subquery and all, so `patients.id` inside a correlated NOT EXISTS
  # became a bare `id` that bound to the subquery's own table. Postgres plans
  # that as a One-Time Filter, which empties the table or spares all of it.
  # Only running the statement against real rows tells the two apart.
  describe 'a write whose predicate correlates a subquery', :integration do
    include_context 'with test compiler'
    include_context 'with database'
    include JadeTables

    let(:source) do
      <<~JADE
module App exposing (delete_unvisited, delete_visited)

import Sql exposing (
  Assignable,
  Assignment,
  Col(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  assign,
  column,
  columns,
  no_joins,
  pk,
  table,
)
import Sql.Expr
import Sql.Query exposing (exists, from, not_exists, where)
import Sql.Write exposing (delete_all, execute)
import Encode
import Decode exposing (Value)


#{jade_table('patients', { id: 'Int', name: 'String' })}


#{jade_table('visits', { id: 'Int', patient_id: 'Int' })}


def unvisited(p: PatientsCols) -> Expr(Bool)
  not_exists(
    from(visits) |> where(columns(visits).patient_id |> Sql.Expr.eq(p.id)),
  )
end


def visited(p: PatientsCols) -> Expr(Bool)
  exists(from(visits) |> where(columns(visits).patient_id |> Sql.Expr.eq(p.id)))
end


def delete_unvisited -> Task(Int, SqlError)
  patients
    |> delete_all(unvisited)
    |> execute
end


def delete_visited -> Task(Int, SqlError)
  patients
    |> delete_all(visited)
    |> execute
end
      JADE
    end

    before do
      test_compiler.require('app', source)
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Seen'), (2, 'Unseen')")
      conn.execute("INSERT INTO visits (patient_id) VALUES (1)")
      conn.execute("SELECT setval('patients_id_seq', 2)")
    end

    def conn = JadeSql::TestDb.connection

    def remaining = conn.execute("SELECT name FROM patients ORDER BY id").map { it['name'] }

    it 'deletes only the rows the subquery does not match' do
      expect(App::Internal.delete_unvisited.run).to be_ok(1)
      expect(remaining).to eql ['Seen']
    end

    it 'deletes only the rows the subquery does match' do
      conn.execute("DELETE FROM visits")
      conn.execute("INSERT INTO visits (patient_id) VALUES (2)")

      expect(App::Internal.delete_visited.run).to be_ok(1)
      expect(remaining).to eql ['Seen']
    end
  end
end
