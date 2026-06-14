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
        module App exposing (find_by_name, insert_patient, list_names, load_tags)

        import Sql exposing (
          Assignment,
          Expr,
          SqlError,
          SqlMapper,
          Table,
          assign,
          column,
          execute,
          fetch_many_raw,
          fetch_one_raw,
          table,
        )
        import Sql.Mutation exposing (insert)
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


        struct NewPatient = {
          name: String,
          balance: Int
        }


        struct PatientsCols = {
          name: Expr(String),
          balance: Expr(Int)
        }


        struct MaybePatientsCols = {
          name: Expr(Maybe(String)),
          balance: Expr(Maybe(Int))
        }


        implements SqlMapper(NewPatient) with
          to_assigns: new_patient_assigns
        end


        def new_patient_assigns(p: NewPatient) -> List(Assignment)
          [assign("name", p.name), assign("balance", p.balance)]
        end


        def patients -> Table(PatientsCols, MaybePatientsCols)
          table(
            "patients",
            "patients",
            (a) -> { PatientsCols(column(a, "name"), column(a, "balance")) },
            (a) -> { MaybePatientsCols(column(a, "name"), column(a, "balance")) },
            ["id"],
          )
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


        def insert_patient(n: String, b: Int) -> Task(Int, SqlError)
          insert(NewPatient(n, b), patients) |> execute
        end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection

    it 'decodes a fetched row into the caller struct' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('Paul', 100)")

      result = App::Internal.find_by_name('Paul').run

      expect(result).to be_ok
      expect(result._1.name).to eql 'Paul'
      expect(result._1.balance).to eql 100
    end

    it 'returns NotFound when no row matches' do
      expect(App::Internal.find_by_name('Nobody').run)
        .to be_err(look_like('Sql::NotFound'))
    end

    it 'persists an inserted row via execute' do
      result = App::Internal.insert_patient('Frank', 200).run

      expect(result).to be_ok(1)
      expect(conn.select_value("SELECT balance FROM patients WHERE name = 'Frank'"))
        .to eql 200
    end

    it 'round-trips a text[] column' do
      conn.execute(
        "INSERT INTO patients (name, balance, tags) VALUES ('Ann', 0, '{vip,beta}')",
      )

      result = App::Internal.load_tags('Ann').run

      expect(result).to be_ok
      expect(result._1.tags).to eql %w[vip beta]
    end

    it 'fetches many rows in order' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('A', 1), ('B', 2)")

      result = App::Internal.list_names.run

      expect(result).to be_ok
      expect(result._1.map(&:name)).to eql %w[A B]
    end
  end
end
