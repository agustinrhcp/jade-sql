require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (
  find_by_name,
  insert_patient,
  list_names,
  literal_q,
  load_numbers,
  load_tags,
  rate_coefficient,
  rate_exponent,
  stacked,
  trailing_semicolon,
  weight_of,
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
  fetch_many_raw,
  fetch_one_raw,
  no_joins,
  pk,
  table,
)
import Sql.Write exposing (insert)
import Decimal exposing (Decimal, coefficient, exponent)
import Encode


struct Patient = {
  id: Int,
  name: String,
  balance: Int
}


struct Tagged = {
  name: String,
  tags: List(String)
}


struct Numbers = {
  name: String,
  rate: Decimal,
  weight: Float
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


implements Assignable(Patient) with
  to_assigns: patient_assigns
end


def patient_assigns(p: Patient) -> List(Assignment)
  [assign("id", p.id), assign("name", p.name), assign("balance", p.balance)]
end


def patients_pk -> Pk(PatientsCols, Int)
  pk("pkey", ["id"], (v) -> { [Encode.encode(v)] })
end


def find_by_name(n: String) -> Task(Patient, SqlError)
  fetch_one_raw(
    ("SELECT id, name, balance FROM patients WHERE name = ?", [Encode.encode(n)]),
  )
end


def list_names -> Task(List(Patient), SqlError)
  fetch_many_raw(("SELECT id, name, balance FROM patients ORDER BY id", []))
end


def load_tags(n: String) -> Task(Tagged, SqlError)
  fetch_one_raw(
    ("SELECT name, tags FROM patients WHERE name = ?", [Encode.encode(n)]),
  )
end


def load_numbers(n: String) -> Task(Numbers, SqlError)
  fetch_one_raw(
    ("SELECT name, rate, weight FROM patients WHERE name = ?", [Encode.encode(n)]),
  )
end


def rate_coefficient(n: String) -> Task(Int, SqlError)
  load_numbers(n) |> Task.map((x) -> { coefficient(x.rate) })
end


def rate_exponent(n: String) -> Task(Int, SqlError)
  load_numbers(n) |> Task.map((x) -> { exponent(x.rate) })
end


def weight_of(n: String) -> Task(Float, SqlError)
  load_numbers(n) |> Task.map((x) -> { x.weight })
end


def insert_patient(n: String, b: Int) -> Task(Int, SqlError)
  insert(NewPatient(n, b), patients) |> execute
end


def literal_q(n: String) -> Task(Patient, SqlError)
  fetch_one_raw(
    (
      "SELECT id, name, balance FROM patients WHERE name <> 'n/a?' AND name = ?",
      [Encode.encode(n)],
    ),
  )
end


def stacked -> Task(List(Patient), SqlError)
  fetch_many_raw(
    ("SELECT id, name, balance FROM patients; DELETE FROM patients", []),
  )
end


def trailing_semicolon -> Task(List(Patient), SqlError)
  fetch_many_raw(("SELECT id, name, balance FROM patients ORDER BY id;", []))
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection

    it 'decodes a fetched row into the caller struct' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('Paul', 100)")

      status, value = App.find_by_name('Paul')

      expect(status).to eql "ok"
      expect(value['name']).to eql 'Paul'
      expect(value['balance']).to eql 100
    end

    it 'decodes numeric exactly as Decimal and double precision as Float' do
      conn.execute(
        "INSERT INTO patients (name, rate, weight) VALUES ('Ada', 0.1750, 62.5)",
      )

      # numeric 0.1750 -> exact Decimal(175, -3); no Float rounding
      expect(App.rate_coefficient('Ada')).to eql ["ok", 175]
      expect(App.rate_exponent('Ada')).to eql ["ok", -3]
      # double precision stays a Float
      expect(App.weight_of('Ada')).to eql ["ok", 62.5]
    end

    it 'returns NotFound when no row matches' do
      expect(App.find_by_name('Nobody'))
        .to eql ["err", ["NotFound"]]
    end

    it 'persists an inserted row via execute' do
      expect(App.insert_patient('Frank', 200)).to eql ["ok", 1]
      expect(conn.select_value("SELECT balance FROM patients WHERE name = 'Frank'"))
        .to eql 200
    end

    it 'round-trips a text[] column' do
      conn.execute(
        "INSERT INTO patients (name, balance, tags) VALUES ('Ann', 0, '{vip,beta}')",
      )

      status, value = App.load_tags('Ann')

      expect(status).to eql "ok"
      expect(value['tags']).to eql %w[vip beta]
    end

    it 'binds params correctly when a string literal contains a ?' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('Paul', 100)")

      status, value = App.literal_q('Paul')

      expect(status).to eql "ok"
      expect(value['name']).to eql 'Paul'
    end

    it 'fetches many rows in order' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('A', 1), ('B', 2)")

      status, value = App.list_names

      expect(status).to eql "ok"
      expect(value.map { it['name'] }).to eql %w[A B]
    end

    it 'refuses a second statement in SQL with nothing to bind' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('A', 1)")

      expect { App.stacked }.to raise_error(ArgumentError, /one statement per call/)
      expect(conn.select_value("SELECT count(*) FROM patients")).to eql 1
    end

    it 'runs SQL that ends in a semicolon' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('A', 1)")

      status, value = App.trailing_semicolon

      expect(status).to eql "ok"
      expect(value.map { it['name'] }).to eql %w[A]
    end
  end
end
