require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'a CASE with an arm per variant, against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (net, signs)

import Sql exposing (
  Col(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  column,
  neg,
  no_joins,
  pk,
  sum,
  table,
  val,
)
import Sql.Expr as Expr exposing (Enum)
import Sql.Query exposing (Select, fetch_many, fetch_one, field, from, order, select)
import Encode


type Kind
  = Income
  | Expense


implements Enum(Kind) with
  variants: kind_variants
end


def kind_variants -> List(Kind)
  [Income, Expense]
end


#{jade_table('entries', { id: 'Int', kind: 'Kind', amount: 'Int' }, pk: 'entries_pk')}


def entries_pk -> Pk(EntriesCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


struct Net = { cents: Maybe(Int) }


struct Sign = { word: String }


def signed(e: EntriesCols) -> Expr(Int)
  e.kind
    |> Expr.match((k) -> {
      case k
      in Income then e.amount
      in Expense then neg(e.amount)
      end
    })
end


def net_q -> Select(Net)
  e <- from(entries)

  select(Net(_)) |> field(sum(signed(e)))
end


def net -> Task(Net, SqlError)
  net_q |> fetch_one
end


def size(e: EntriesCols) -> Expr(String)
  e.amount
    |> Expr.gt(val(100))
    |> Expr.match((big) -> {
      big ? val("big") : val("small")
    })
end


def signs_q -> Select(Sign)
  e <- from(entries)

  select(Sign(_))
    |> field(size(e))
    |> order(e.id)
end


def signs -> Task(List(Sign), SqlError)
  signs_q |> fetch_many
end
      JADE
    end

    def conn = JadeSql::TestDb.connection

    before do
      conn.execute(<<~SQL)
        DROP TABLE IF EXISTS entries;
        DROP TYPE IF EXISTS entry_kind;
        CREATE TYPE entry_kind AS ENUM ('income', 'expense');
        CREATE TABLE entries (id integer PRIMARY KEY, kind entry_kind NOT NULL, amount integer NOT NULL);
        INSERT INTO entries VALUES (1, 'income', 500), (2, 'expense', 80), (3, 'expense', 120);
      SQL
      test_compiler.require('app', source)
    end

    after { conn.execute('DROP TABLE entries; DROP TYPE entry_kind') }

    it 'gives every variant its arm, bound against the enum column' do
      expect(App.net).to eql ['ok', { 'cents' => 300 }]
    end

    it 'cases on a Bool the same way' do
      expect(App.signs).to eql ['ok', [{ 'word' => 'big' }, { 'word' => 'small' }, { 'word' => 'big' }]]
    end
  end
end
