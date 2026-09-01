require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql.transaction against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (
  commit_two,
  inner_only_rollback,
  nested_commit,
  nested_rollback,
  rollback_on_err,
  single_count,
)

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
  fetch_one_raw,
  no_joins,
  pk,
  table,
  transaction,
)
import Sql.Write exposing (insert)
import Encode


struct Patient = {
  id: Int,
  name: String,
  balance: Int
}


struct NewPatient = {
  name: String,
  balance: Int
}


#{jade_table('patients', { name: 'String', balance: 'Int' }, pk: 'patients_pk')}


implements Assignable(NewPatient) with
  to_assigns: new_patient_assigns
end


def new_patient_assigns(p: NewPatient) -> List(Assignment)
  [assign("name", p.name), assign("balance", p.balance)]
end


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def add(n: String, b: Int) -> Task(Int, SqlError)
  insert(NewPatient(n, b), patients) |> execute
end


def find_missing -> Task(Patient, SqlError)
  fetch_one_raw(
    (
      "SELECT id, name, balance FROM patients WHERE name = ?",
      [Encode.encode("nope")],
    ),
  )
end


def commit_two -> Task(Int, SqlError)
  transaction(
    add("A", 1) |> Task.and_then((_) -> { add("B", 2) }),
  )
end


def rollback_on_err -> Task(Patient, SqlError)
  transaction(
    add("C", 3) |> Task.and_then((_) -> { find_missing }),
  )
end


def single_count -> Task(Int, SqlError)
  transaction(add("solo", 9))
end


def nested_commit -> Task(Int, SqlError)
  transaction(
    add("outer", 1) |> Task.and_then((_) -> { transaction(add("inner", 2)) }),
  )
end


def nested_rollback -> Task(Patient, SqlError)
  transaction(
    add("outer", 1)
      |> Task.and_then((_) -> { transaction(add("inner", 2)) })
      |> Task.and_then((_) -> { find_missing }),
  )
end


def add_then_fail -> Task(Patient, SqlError)
  add("inner", 2) |> Task.and_then((_) -> { find_missing })
end


def recover(t: Task(Patient, SqlError)) -> Task(Int, SqlError)
  t
    |> Task.map((_) -> { 0 })
    |> Task.on_error((_) -> { Task.succeed(0) })
end


def inner_only_rollback -> Task(Int, SqlError)
  transaction(
    add("outer", 1)
      |> Task.and_then((_) -> { recover(transaction(add_then_fail)) })
      |> Task.and_then((_) -> { add("after", 3) }),
  )
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection
    def patient_count = conn.select_value("SELECT count(*) FROM patients")

    def patient_names
      conn.select_values("SELECT name FROM patients ORDER BY name")
    end

    it 'commits every statement when the task succeeds' do
      expect(App::Internal.commit_two.run).to be_ok
      expect(patient_count).to eql 2
    end

    it 'commits a single-statement transaction' do
      expect(App::Internal.single_count.run).to be_ok(1)
      expect(patient_count).to eql 1
    end

    it 'rolls back every statement and re-raises when the task errs' do
      result = App::Internal.rollback_on_err.run

      expect(result).to be_err(look_like('Sql::NotFound'))
      expect(patient_count).to eql 0
    end

    it 'commits a nested transaction along with the outer one' do
      expect(App::Internal.nested_commit.run).to be_ok
      expect(patient_count).to eql 2
    end

    it 'rolls back work a nested transaction already committed' do
      result = App::Internal.nested_rollback.run

      expect(result).to be_err(look_like('Sql::NotFound'))
      expect(patient_count).to eql 0
    end

    it 'rolls back only the nested transaction when its error is recovered' do
      expect(App::Internal.inner_only_rollback.run).to be_ok
      expect(patient_names).to eql %w[after outer]
    end

    it 'takes part in a surrounding ActiveRecord transaction' do
      ::ActiveRecord::Base.transaction do
        expect(App::Internal.single_count.run).to be_ok(1)
        raise ::ActiveRecord::Rollback
      end

      expect(patient_count).to eql 0
    end
  end
end
