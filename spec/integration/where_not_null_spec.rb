require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # A nullable column is `Expr(Maybe(a))`, and the only way to spend it as an
  # `Expr(a)` is the call that also filters the NULLs out of the query.
  describe 'a column narrowed by the predicate that requires it', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (seen_days, total)

import Calendar exposing (Date)
import Sql exposing (
  Col(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  column,
  no_joins,
  pk,
  sum,
  table,
)
import Sql.Query exposing (
  Select,
  fetch_many,
  fetch_one,
  field,
  from,
  order,
  select,
  where_not_null,
)
import Encode


#{jade_table('visits', { id: 'Int', patient_id: 'Int', seen_on: 'Maybe(Date)' }, pk: 'visits_pk')}


def visits_pk -> Pk(VisitsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


struct Day = { on: Date }


struct Total = { patients: Maybe(Int) }


def seen_days_q -> Select(Day)
  v <- from(visits)
  seen_on <- where_not_null(v.seen_on)

  select(Day(_))
    |> field(seen_on)
    |> order(v.id)
end


def seen_days -> Task(List(Day), SqlError)
  seen_days_q |> fetch_many
end


def total_q -> Select(Total)
  v <- from(visits)
  seen_on <- where_not_null(v.seen_on)

  select(Total(_)) |> field(sum(v.patient_id))
end


def total -> Task(Total, SqlError)
  total_q |> fetch_one
end
      JADE
    end

    def conn = JadeSql::TestDb.connection

    before do
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Ada')")
      conn.execute(<<~SQL)
        INSERT INTO visits (id, patient_id, seen_on) VALUES
          (10, 1, '2026-09-01'), (11, 1, NULL), (12, 1, '2026-09-03')
      SQL
      test_compiler.require('app', source)
    end

    it 'reads the column as the type it now has' do
      expect(App.seen_days)
        .to eql ['ok', [{ 'on' => '2026-09-01' }, { 'on' => '2026-09-03' }]]
    end

    it 'filters the query, not only the type' do
      expect(App.total).to eql ['ok', { 'patients' => 2 }]
    end
  end
end
