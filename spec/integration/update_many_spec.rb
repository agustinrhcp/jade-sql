require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql.Write.update_many against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    def conn = JadeSql::TestDb.connection

    let(:source) do
      <<~JADE
module App exposing (add, rewrite)

import Sql exposing (
  Assignable,
  Assignment,
  Col(..),
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  assign,
  column,
  execute,
  no_joins,
  pk,
  table,
)
import Sql.Write exposing (insert, update_many)
import Encode
import Decode exposing (Value)


struct Patient = {
  id: Int,
  name: String,
  balance: Int
}


struct NewPatient = { name: String }


#{jade_table('patients', { name: 'String', balance: 'Int' }, pk: 'patients_pk')}


implements Assignable(NewPatient) with
  to_assigns: new_assigns
end


def new_assigns(p: NewPatient) -> List(Assignment)
  [assign("name", p.name)]
end


implements Assignable(Patient) with
  to_assigns: patient_assigns
end


def patient_assigns(p: Patient) -> List(Assignment)
  [assign("id", p.id), assign("name", p.name), assign("balance", p.balance)]
end


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def add(name: String) -> Task(Int, SqlError)
  insert(NewPatient(name), patients) |> execute
end


def rewrite(rows: List(Patient)) -> Task(Int, SqlError)
  rows
    |> List.map((p) -> { (p.id, p) })
    |> update_many(patients)
    |> execute
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def seed(*names)
      names.each { App::Internal.add(it).run }
      conn.select_all('SELECT id FROM patients ORDER BY id').rows.flatten
    end

    it 'writes every row in one statement' do
      a, b, c = seed('Ada', 'Grace', 'Barbara')

      rows = [
        App::Patient[a, 'Ada L', 10],
        App::Patient[b, 'Grace H', 20],
      ]

      expect(App::Internal.rewrite(rows).run).to be_ok(2)

      expect(conn.select_all('SELECT id, name, balance FROM patients ORDER BY id').to_a)
        .to eql(
          [
            { 'id' => a, 'name' => 'Ada L', 'balance' => 10 },
            { 'id' => b, 'name' => 'Grace H', 'balance' => 20 },
            { 'id' => c, 'name' => 'Barbara', 'balance' => 0 },
          ],
        )
    end

    it 'keeps the statement the same size as the batch grows' do
      ids = seed(*Array.new(50) { "p#{it}" })

      rows = ids.map { App::Patient[it, "n#{it}", it] }

      sql = nil
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, p|
        sql = p[:sql] if p[:sql].start_with?('UPDATE')
      end

      expect(App::Internal.rewrite(rows).run).to be_ok(50)

      expect(sql.length).to be < 200
      expect(conn.select_value('SELECT count(*) FROM patients WHERE name LIKE $1', 'x', ['n%']))
        .to eql 50
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
