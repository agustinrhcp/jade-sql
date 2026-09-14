require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # Postgres spells four of its jsonb operators with a `?`, and the runtime
  # rewrites every `?` outside a quoted span into a `$n` placeholder. A
  # builder spec cannot see the collision — the SQL it asserts is the SQL
  # before that rewrite — so only running the statement says whether the
  # operator survived.
  describe 'a jsonb predicate against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'
    include JadeTables

    let(:source) do
      <<~JADE
module App exposing (matching, seed)

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
  execute,
  jsonb_path_exists,
  no_joins,
  pk,
  table,
  to_assigns,
)
import Sql.Query exposing (Select, fetch_many, field, from, select, where)
import Sql.Write exposing (insert)
import Decode exposing (Value)
import Encode


#{jade_table('patients', { id: 'Int', name: 'String', rules: 'Decode.Value' })}


struct Row = { name: String }


def seed -> Task(Int, SqlError)
  [
    assign("name", "Ada"),
    Assignment("rules", "?::jsonb", [Encode.string("{\\"kind\\":\\"income\\"}")]),
  ]
    |> insert(patients)
    |> execute
end


def by_path(path: String) -> Select(Row)
  p <- from(patients)

  select(Row(_))
    |> field(p.name)
    |> where(jsonb_path_exists(p.rules, path))
end


def matching(path: String) -> Task(List(Row), SqlError)
  fetch_many(by_path(path))
end
      JADE
    end

    before do
      test_compiler.require('app', source)
      App.seed
    end

    # The path itself contains a `?`, which is a jsonpath filter and travels
    # as a bound value rather than as SQL.
    it 'runs a path whose filter spells itself with a question mark' do
      expect(App.matching('$.kind ? (@ == "income")'))
        .to eql ['ok', [{ 'name' => 'Ada' }]]
    end

    it 'finds nothing when the path does not match' do
      expect(App.matching('$.kind ? (@ == "expense")')).to eql ['ok', []]
    end

    # Two parameters, so a placeholder miscount shows up as the wrong one
    # being bound rather than as a syntax error.
    it 'numbers the placeholders around it correctly' do
      expect(App.matching('$.nope')).to eql ['ok', []]
    end
  end
end
