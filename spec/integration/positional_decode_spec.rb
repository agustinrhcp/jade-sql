require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  # The type-checker matches each `field` to the constructor argument in the
  # same position, so a row has to be read back the same way. None of these
  # columns comes back under the name of the field it fills.
  describe 'a projection, read back by position', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (both_ids, counted, labels, removed)

import Sql exposing (
  Col(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  column,
  count_all,
  is_not_null,
  no_joins,
  pk,
  table,
)
import Sql.Expr as Expr
import Sql.Query exposing (Select, fetch_many, fetch_one, field, from, join, select)
import Sql.Write as Write
import Encode


#{jade_table('patients', { id: 'Int', name: 'String' }, pk: 'patients_pk')}


#{jade_table('visits', { id: 'Int', patient_id: 'Int' }, pk: 'visits_pk')}


def patients_pk -> Pk(PatientsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


def visits_pk -> Pk(VisitsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


struct Label = { label: String }


struct Pair = {
  patient: Int,
  visit: Int
}


struct Tally = { total: Int }


def labels_q -> Select(Label)
  p <- from(patients)

  select(Label(_)) |> field(p.name)
end


def labels -> Task(List(Label), SqlError)
  labels_q |> fetch_many
end


def both_ids_q -> Select(Pair)
  p <- from(patients)
  v <- visits |> join((x) -> { p.id |> Expr.eq(x.patient_id) })

  select(Pair(_, _))
    |> field(p.id)
    |> field(v.id)
end


def both_ids -> Task(List(Pair), SqlError)
  both_ids_q |> fetch_many
end


def counted_q -> Select(Tally)
  p <- from(patients)

  select(Tally(_)) |> field(count_all)
end


def counted -> Task(Tally, SqlError)
  counted_q |> fetch_one
end


def removed -> Task(List(Label), SqlError)
  Write.delete_all(patients, (p) -> { is_not_null(p.id) })
    |> Write.returning_with((p) -> { select(Label(_)) |> field(p.name) })
    |> Write.fetch_many
end
      JADE
    end

    before do
      test_compiler.require('app', source)
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Ada'), (2, 'Bob')")
      conn.execute('INSERT INTO visits (id, patient_id) VALUES (10, 1)')
    end

    def conn = JadeSql::TestDb.connection

    it 'fills a field whose name the column does not share' do
      expect(App.labels).to eql ['ok', [{ 'label' => 'Ada' }, { 'label' => 'Bob' }]]
    end

    it 'keeps both of two columns that share a name' do
      expect(App.both_ids).to eql ['ok', [{ 'patient' => 1, 'visit' => 10 }]]
    end

    it 'reads a computed column without naming it' do
      expect(App.counted).to eql ['ok', { 'total' => 2 }]
    end

    it 'reads RETURNING the same way' do
      expect(App.removed.then { [it[0], it[1].sort_by { it['label'] }] })
        .to eql ['ok', [{ 'label' => 'Ada' }, { 'label' => 'Bob' }]]
    end
  end
end
