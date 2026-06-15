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
          rate_exponent,
          rate_mantissa,
          weight_of,
        )

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
        import Sql.Decimal exposing (Decimal, exponent, mantissa)
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


        def load_numbers(n: String) -> Task(Numbers, SqlError)
          fetch_one_raw(
            ("SELECT name, rate, weight FROM patients WHERE name = ?", [Encode.encode(n)]),
          )
        end


        def rate_mantissa(n: String) -> Task(Int, SqlError)
          load_numbers(n) |> Task.map((x) -> { mantissa(x.rate) })
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

    it 'decodes numeric exactly as Decimal and double precision as Float' do
      conn.execute(
        "INSERT INTO patients (name, rate, weight) VALUES ('Ada', 0.1750, 62.5)",
      )

      # numeric 0.1750 -> exact Decimal(175, -3); no Float rounding
      expect(App::Internal.rate_mantissa('Ada').run).to be_ok(175)
      expect(App::Internal.rate_exponent('Ada').run).to be_ok(-3)
      # double precision stays a Float
      expect(App::Internal.weight_of('Ada').run).to be_ok(62.5)
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

    it 'binds params correctly when a string literal contains a ?' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('Paul', 100)")

      result = App::Internal.literal_q('Paul').run

      expect(result).to be_ok
      expect(result._1.name).to eql 'Paul'
    end

    it 'fetches many rows in order' do
      conn.execute("INSERT INTO patients (name, balance) VALUES ('A', 1), ('B', 2)")

      result = App::Internal.list_names.run

      expect(result).to be_ok
      expect(result._1.map(&:name)).to eql %w[A B]
    end
  end
end
