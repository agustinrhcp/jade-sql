require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'an unprojected read after a join, against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (visit_rows)

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
  table,
)
import Sql.Expr as Expr
import Encode
import Sql.Query exposing (Query, Select, fetch_many, field, from, join, select)


#{jade_table('patients', { id: 'Int', name: 'String' }, pk: 'patients_pk')}


#{jade_table('visits', { id: 'Int', patient_id: 'Int' }, pk: 'visits_pk')}


def patients_pk -> Pk(PatientsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


def visits_pk -> Pk(VisitsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


struct VisitRow = {
  id: Int,
  patient_id: Int
}


def with_visits -> Select(VisitRow)
  p <- from(patients)
  v <- visits |> join((x) -> { p.id |> Expr.eq(x.patient_id) })

  select(VisitRow(_, _))
    |> field(v.id)
    |> field(v.patient_id)
end


def visit_rows -> Task(List(VisitRow), SqlError)
  with_visits |> fetch_many
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection

    it 'reads the table whose columns the query carries' do
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Ada'), (2, 'Bob')")
      conn.execute("INSERT INTO visits (id, patient_id) VALUES (10, 1), (11, 1)")

      status, rows = App.visit_rows

      expect(status).to eql "ok"
      expect(rows.map { [it['id'], it['patient_id']] }.sort).to eql [[10, 1], [11, 1]]
    end
  end
end
