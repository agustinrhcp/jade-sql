require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # Each expression's type is the type of the SQL it renders, which only
  # Postgres can confirm: the row decodes into the field the type names.
  describe 'computed expressions, against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (aggregates, per_row)

import Calendar exposing (Date, Month(..))
import Decimal exposing (Decimal)
import Decode exposing (Value)
import Sql exposing (
  Col(..),
  DateUnit(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  avg,
  column,
  count_distinct,
  json_text,
  lower,
  max,
  min,
  no_joins,
  pk,
  sum,
  table,
  trunc_date,
  upper,
  val,
)
import Sql.Expr as Expr exposing (case_when)
import Sql.Query exposing (Select, fetch_many, fetch_one, field, from, order, select)
import Encode


#{jade_table('patients', { id: 'Int', name: 'String', balance: 'Int', rules: 'Value' }, pk: 'patients_pk')}


def patients_pk -> Pk(PatientsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


struct PerRow = {
  shout: String,
  whisper: String,
  tag: String,
  net: Int,
  band: String,
  latest: Int,
  plan: Maybe(String)
}


struct Totals = {
  high: Maybe(Int),
  low: Maybe(Int),
  mean: Maybe(Decimal),
  patients: Int,
  rich: Int,
  month_start: Date,
  week_later: Date
}


def band(p: PatientsCols) -> Expr(String)
  case_when(p.balance |> Expr.lt(val(0)), val("owes"))
    |> Expr.when(p.balance |> Expr.gt(val(100)), val("credit"))
    |> Expr.otherwise(val("even"))
end


def per_row_q -> Select(PerRow)
  p <- from(patients)

  select(PerRow(_, _, _, _, _, _, _))
    |> field(upper(p.name))
    |> field(lower(p.name))
    |> field(p.name |> Expr.concat(val("!")))
    |> field(
      p.balance
        |> Expr.times(val(2))
        |> Expr.minus(val(10))
        |> Expr.div(val(4))
        |> Expr.plus(val(1)),
    )
    |> field(band(p))
    |> field(p.balance
      |> Expr.greatest(p.id)
      |> Expr.least(val(300)))
    |> field(json_text(p.rules, "plan"))
    |> order(p.id)
end


def per_row -> Task(List(PerRow), SqlError)
  per_row_q |> fetch_many
end


def aggregates_q -> Select(Totals)
  p <- from(patients)

  select(Totals(_, _, _, _, _, _, _))
    |> field(max(p.balance))
    |> field(min(p.balance))
    |> field(avg(p.balance))
    |> field(count_distinct(p.name))
    |> field(
      sum(p.balance)
        |> Expr.filter_where(p.balance |> Expr.gt(val(100)))
        |> Expr.coalesce(val(0)),
    )
    |> field(trunc_date(Month, val(september_18)))
    |> field(val(september_18) |> Expr.plus_days(val(7)))
end


def september_18 -> Date
  Calendar.from_calendar_date(2026, Sep, 18)
end


def aggregates -> Task(Totals, SqlError)
  aggregates_q |> fetch_one
end
      JADE
    end

    def conn = JadeSql::TestDb.connection

    before do
      conn.execute(<<~SQL)
        INSERT INTO patients (id, name, balance, rules) VALUES
          (1, 'Ada', 250, '{"plan": "gold"}'),
          (2, 'Bob', -30, '{}'),
          (3, 'Cy', 50, '{"plan": "basic"}')
      SQL
      test_compiler.require('app', source)
    end

    it 'computes per row' do
      expect(App.per_row).to eql ['ok', [
        { 'shout' => 'ADA', 'whisper' => 'ada', 'tag' => 'Ada!', 'net' => 123,
          'band' => 'credit', 'latest' => 250, 'plan' => 'gold' },
        { 'shout' => 'BOB', 'whisper' => 'bob', 'tag' => 'Bob!', 'net' => -16,
          'band' => 'owes', 'latest' => 2, 'plan' => nil },
        { 'shout' => 'CY', 'whisper' => 'cy', 'tag' => 'Cy!', 'net' => 23,
          'band' => 'even', 'latest' => 50, 'plan' => 'basic' },
      ]]
    end

    it 'aggregates' do
      status, totals = App.aggregates

      expect(status).to eql 'ok'
      expect(totals).to eql(
        'high' => 250,
        'low' => -30,
        'mean' => '9e1',
        'patients' => 3,
        'rich' => 250,
        'month_start' => '2026-09-01',
        'week_later' => '2026-09-25',
      )
    end
  end
end
