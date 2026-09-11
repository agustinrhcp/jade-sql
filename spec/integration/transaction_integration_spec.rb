require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module ActiveRecordBlockPorts
  extend Jade::Port

  task :rolled_back_ar_block do |t|
    ::ActiveRecord::Base.transaction do
      ::ActiveRecord::Base.connection.execute(
        "INSERT INTO patients (name, balance) VALUES ('ar', 0)",
      )
      raise ::ActiveRecord::Rollback
    end
    t.ok(true)
  end
end

module Jade
  describe 'Sql.transaction against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (
  ar_block_inside,
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
  Col(..),
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


uses ActiveRecordBlockPorts with
  rolled_back_ar_block : Task(Bool, SqlError)
end


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
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
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


def ar_block_inside -> Task(Bool, SqlError)
  transaction(rolled_back_ar_block())
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
      expect(App.commit_two[0]).to eql "ok"
      expect(patient_count).to eql 2
    end

    it 'commits a single-statement transaction' do
      expect(App.single_count).to eql ["ok", 1]
      expect(patient_count).to eql 1
    end

    it 'rolls back every statement and re-raises when the task errs' do
      expect(App.rollback_on_err).to eql ["err", ["NotFound"]]
      expect(patient_count).to eql 0
    end

    it 'commits a nested transaction along with the outer one' do
      expect(App.nested_commit[0]).to eql "ok"
      expect(patient_count).to eql 2
    end

    it 'rolls back work a nested transaction already committed' do
      expect(App.nested_rollback).to eql ["err", ["NotFound"]]
      expect(patient_count).to eql 0
    end

    it 'rolls back only the nested transaction when its error is recovered' do
      expect(App.inner_only_rollback[0]).to eql "ok"
      expect(patient_names).to eql %w[after outer]
    end

    it 'takes part in a surrounding ActiveRecord transaction' do
      ::ActiveRecord::Base.transaction do
        expect(App.single_count).to eql ["ok", 1]
        raise ::ActiveRecord::Rollback
      end

      expect(patient_count).to eql 0
    end

    it 'lets an ActiveRecord block inside it roll back on its own' do
      expect(App.ar_block_inside).to eql ["ok", true]
      expect(patient_count).to eql 0
    end
  end
end
