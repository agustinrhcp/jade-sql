require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'a runner handing back the app\'s own error, against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (AppError(..), counted, found, missing)

import Sql exposing (
  Col(..),
  Expr,
  FromSqlError,
  NoJoins,
  Pk,
  SqlError(..),
  Table,
  column,
  eq,
  no_joins,
  pk,
  table,
)
import Encode
import Sql.Query as Query exposing (Select, fetch_one, from, selected)


#{jade_table('patients', { id: 'Int', name: 'String' }, pk: 'patients_pk')}


def patients_pk -> Pk(PatientsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


type AppError
  = RecordNotFound
  | DbFailure


implements FromSqlError(AppError) with
  from_sql_error: sql_to_app
end


def sql_to_app(e: SqlError) -> AppError
  case e
  in NotFound then RecordNotFound
  else DbFailure
  end
end


def one(id: Int) -> Select({ id: Int, name: String })
  cols <- from(patients)

  from(patients)
    |> Query.where(eq(cols.id, id))
    |> selected
end


def found -> Task({ id: Int, name: String }, AppError)
  one(1) |> fetch_one
end


def missing -> Task({ id: Int, name: String }, AppError)
  one(99) |> fetch_one
end


def counted -> Task({ id: Int, name: String }, SqlError)
  one(1) |> fetch_one
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection

    it 'hands back the app error the signature asks for' do
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Ada')")

      status, row = App.found

      expect(status).to eql "ok"
      expect(row['name']).to eql 'Ada'
    end

    it 'converts a missing row into the app error, not SqlError' do
      status, err = App.missing

      expect(status).to eql "err"
      expect(err).to eql 'record_not_found'
    end

    it 'still hands back SqlError where that is what was asked for' do
      conn.execute("INSERT INTO patients (id, name) VALUES (1, 'Ada')")

      status, row = App.counted

      expect(status).to eql "ok"
      expect(row['name']).to eql 'Ada'
    end
  end
end
