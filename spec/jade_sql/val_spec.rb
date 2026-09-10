require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'

module Jade
  # The operators take values directly, so `val` is for the positions that
  # cannot: a constant where an expression is wanted.
  describe 'Sql.val' do
    include_context 'with test compiler'
    include JadeTables

    before do
      test_compiler.require('app', <<~JADE)
module App exposing (constant_field, constant_prop)

import Sql exposing (
  Assignable,
  Assignment(..),
  Col(..),
  Expr,
  NoJoins,
  Pk,
  Selector,
  Table,
  assign,
  column,
  no_joins,
  pk,
  table,
  to_assigns,
  val,
)
import Sql.Json as Json exposing (Json)
import Sql.Query exposing (Select, field, field_as, from, select, to_sql)
import Decode exposing (Value)
import Encode


#{jade_table('patients', { id: 'Int', name: 'String' })}


struct Row = {
  id: Int,
  kind: String
}


def tagged -> Select(Row)
  p <- from(patients)

  select(Row(_, _))
    |> field(p.id)
    |> field_as(val("patient"), "kind")
end


def constant_field -> (String, List(Value))
  tagged |> to_sql
end


def constant_prop -> Expr(Json(Row))
  Json.object(Row(_, _))
    |> Json.prop("id", column("p", "id"))
    |> Json.prop("kind", val("patient"))
    |> Json.build
end
      JADE
    end

    it 'places a constant in a projection, bound rather than inlined' do
      sql, params = App.constant_field

      expect(sql).to eql 'SELECT patients.id, ? AS kind FROM patients patients'
      expect(params).to eql ['patient']
    end

    it 'places a constant in a JSON document' do
      expect(App.constant_prop).to eql(
        { 'sql' => "json_build_object('id', p.id, 'kind', ?)", 'params' => ['patient'] },
      )
    end
  end
end
