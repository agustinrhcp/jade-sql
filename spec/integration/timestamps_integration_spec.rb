require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql.Write.timestamped against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    def conn = JadeSql::TestDb.connection

    let(:source) do
      <<~JADE
module App exposing (add_plain, add_stamped, add_stamped_value, touch)

import Sql exposing (
  Assignable,
  Assignment,
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
import Sql.Write exposing (insert, stamped, timestamped, update)
import Encode
import Decode exposing (Value)


struct Patient = {
  id: Int,
  name: String
}


struct NewPatient = { name: String }


#{jade_table('patients', { id: 'Int', name: 'String' }, pk: 'patients_pk')}


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
  [assign("id", p.id), assign("name", p.name)]
end


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def add_stamped(name: String) -> Task(Int, SqlError)
  insert(NewPatient(name), patients)
    |> timestamped
    |> execute
end


def add_stamped_value(name: String) -> Task(Int, SqlError)
  insert(NewPatient(name) |> stamped, patients) |> execute
end


def add_plain(name: String) -> Task(Int, SqlError)
  insert(NewPatient(name), patients) |> execute
end


def touch(id: Int, name: String) -> Task(Int, SqlError)
  update(Patient(id, name), patients, id)
    |> timestamped
    |> execute
end
      JADE
    end

    before { test_compiler.require('app', source) }

    it 'fills created_at and updated_at on insert, with the same instant' do
      expect(App::Internal.add_stamped('Paul').run).to be_ok(1)

      row = conn.select_one("SELECT created_at, updated_at FROM patients WHERE name = 'Paul'")
      expect(row["created_at"]).not_to be_nil
      expect(row["updated_at"]).not_to be_nil
      expect(row["created_at"]).to eq row["updated_at"]
    end

    it 'fills them from the value too, which is where the check can see them' do
      expect(App::Internal.add_stamped_value('Ada').run).to be_ok(1)

      row = conn.select_one("SELECT name, created_at, updated_at FROM patients WHERE name = 'Ada'")
      expect(row["created_at"]).not_to be_nil
      expect(row["created_at"]).to eq row["updated_at"]
    end

    it 'leaves timestamps untouched on a plain insert' do
      App::Internal.add_plain('Frank').run

      row = conn.select_one("SELECT created_at, updated_at FROM patients WHERE name = 'Frank'")
      expect(row["created_at"]).to be_nil
      expect(row["updated_at"]).to be_nil
    end

    it 'sets only updated_at on a timestamped update' do
      App::Internal.add_plain('Ann').run
      id = conn.select_value("SELECT id FROM patients WHERE name = 'Ann'")

      expect(App::Internal.touch(id, 'Annie').run).to be_ok(1)

      row = conn.select_one("SELECT name, created_at, updated_at FROM patients WHERE id = #{id}")
      expect(row["name"]).to eq 'Annie'
      expect(row["updated_at"]).not_to be_nil
      expect(row["created_at"]).to be_nil
    end
  end
end
