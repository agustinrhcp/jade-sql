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
        module App exposing (commit_two, rollback_on_err, single_count)

        import Sql exposing (
          Assignment,
          Expr,
          SqlError,
          SqlMapper,
          Table,
          assign,
          column,
          execute,
          fetch_one_raw,
          table,
          transaction,
        )
        import Sql.Mutation exposing (insert)
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
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection
    def patient_count = conn.select_value("SELECT count(*) FROM patients")

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
  end
end
