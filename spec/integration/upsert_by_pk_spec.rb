require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # `upsert_all` targets the primary key, and the primary key is a unique
  # index like any other — Postgres arbitrates on it by column and reports its
  # constraint name when one is violated. `by_pk` is what hands both to a
  # write, so nothing is generated for it.
  describe 'a conflict on the primary key', :integration do
    include_context 'with test compiler'
    include_context 'with database'
    include JadeTables

    let(:source) do
      <<~JADE
module App exposing (name_of, seed, upsert, violation)

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
  by_pk,
  column,
  eq,
  no_joins,
  pk,
  set_excluded,
  table,
  to_assigns,
)
import Sql.Query exposing (Select, fetch_one, field, from, select, where)
import Sql.Write exposing (do_nothing, do_update, execute, insert, on_conflict)
import Decode exposing (Value)
import Encode


#{jade_table('patients', { id: 'Int', name: 'String' })}


struct Row = {
  id: Int,
  name: String
}


def row(id: Int, name: String) -> List(Assignment)
  [assign("id", id), assign("name", name)]
end


def seed -> Task(Int, SqlError)
  row(1, "old")
    |> insert(patients)
    |> execute
end


def upsert -> Task(Int, SqlError)
  row(1, "new")
    |> insert(patients)
    |> on_conflict(by_pk(patients), do_update((s) -> { [set_excluded(s.name)] }))
    |> execute
end


def violation -> Task(Int, SqlError)
  row(1, "clash")
    |> insert(patients)
    |> execute
end


def one -> Select(Row)
  p <- from(patients)

  select(Row(_, _))
    |> field(p.id)
    |> field(p.name)
    |> where(p.id |> eq(1))
end


def name_of -> Task(Row, SqlError)
  fetch_one(one)
end
      JADE
    end

    before do
      test_compiler.require('app', source)
      App.seed
    end

    it 'updates the row the key already names' do
      expect(App.upsert).to eql ['ok', 1]
      expect(App.name_of).to eql ['ok', { 'id' => 1, 'name' => 'new' }]
    end

    # The name has to be the one Postgres reports, or a caller routing on it
    # silently never matches.
    it 'carries the constraint name a violation reports' do
      expect(App.violation).to eql ['err', ['UniqueViolation', 'patients_pkey']]
    end
  end
end
