require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # A write with nothing to write is ordinary: a changeset whose fields all
  # held their old values, an empty batch. What it must not do is claim to
  # have written something. Rendering specs cannot tell the two apart —
  # `exec_update` returns the number of rows a SELECT matched just as happily
  # as the number an UPDATE changed — so this asks the database.
  describe 'a write with nothing to write', :integration do
    include_context 'with test compiler'
    include_context 'with database'
    include JadeTables

    let(:source) do
      <<~JADE
module App exposing (empty_batch, empty_update_batch, no_assignments, read_back)

import Sql exposing (
  Assignable,
  Assignment(..),
  Col(..),
  Expr,
  NoJoins,
  Pk,
  Selector,
  SqlError,
  Table,
  assign,
  column,
  eq,
  execute,
  no_joins,
  pk,
  set,
  table,
  to_assigns,
)
import Sql.Query exposing (Select, fetch_one, field, from, select, where)
import Sql.Write exposing (insert_all, to_sql, update_all, update_many)
import Decode exposing (Value)
import Encode


#{jade_table('patients', { id: 'Int', name: 'String', balance: 'Int' })}


struct Patient = {
  id: Int,
  name: String,
  balance: Int
}


def no_rows -> List(List(Assignment))
  []
end


def no_assignments -> Task(Int, SqlError)
  patients
    |> update_all((p) -> { p.name |> eq("Ada") }, (p, s) -> { [] })
    |> execute
end


def no_pairs -> List((Int, Patient))
  []
end


def empty_update_batch -> Task(Int, SqlError)
  no_pairs
    |> update_many(patients)
    |> execute
end


def empty_batch -> Task(Int, SqlError)
  no_rows
    |> insert_all(patients)
    |> execute
end


def ada -> Select(Patient)
  p <- from(patients)

  select(Patient(_, _, _))
    |> field(p.id)
    |> field(p.name)
    |> field(p.balance)
    |> where(p.name |> eq("Ada"))
end


def read_back -> Task(Patient, SqlError)
  fetch_one(ada)
end
      JADE
    end

    before do
      test_compiler.require('app', source)
      conn.execute("INSERT INTO patients (name, balance) VALUES ('Ada', 7)")
    end

    def conn = JadeSql::TestDb.connection

    def rows = conn.execute("SELECT count(*) FROM patients").first['count']

    it 'reports no rows updated when there is nothing to set' do
      expect(App.no_assignments).to eql ["ok", 0]
    end

    it 'leaves the row it would have updated alone' do
      App.no_assignments

      expect(App.read_back).to eql ['ok', { 'id' => 1, 'name' => 'Ada', 'balance' => 7 }]
    end

    it 'reports no rows inserted for an empty batch, and does not fail' do
      expect(App.empty_batch).to eql ["ok", 0]
      expect(rows).to eql 1
    end

    # It rendered `WHERE jade_tgt.id = jade_src.id` with neither in scope.
    it 'reports no rows updated for an empty batch, and does not fail' do
      expect(App.empty_update_batch).to eql ["ok", 0]
      expect(App.read_back).to eql ['ok', { 'id' => 1, 'name' => 'Ada', 'balance' => 7 }]
    end
  end
end
