require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql.Query.in_batches against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    def conn = JadeSql::TestDb.connection

    let(:source) do
      <<~JADE
        module App exposing (add, bump_all, count_all_rows)

        import Sql exposing (
          Assignment,
          Expr,
          Selector(..),
          SqlError,
          SqlMapper,
          Table,
          assign,
          column,
          execute,
          fetch_one_raw,
          table,
        )
        import Sql.Query exposing (Q, field, from, in_batches, order, select)
        import Sql.Mutation exposing (insert)
        import Encode exposing (encode)
        import Decode exposing (Value)


        struct Patient = {
          id: Int,
          name: String,
          balance: Int
        }


        struct NewPatient = { name: String }


        struct PatientsCols = {
          id: Expr(Int),
          name: Expr(String),
          balance: Expr(Int)
        }


        struct MaybePatientsCols = {
          id: Expr(Maybe(Int)),
          name: Expr(Maybe(String)),
          balance: Expr(Maybe(Int))
        }


        implements SqlMapper(NewPatient) with
          to_assigns: new_assigns
        end


        def new_assigns(p: NewPatient) -> List(Assignment)
          [assign("name", p.name)]
        end


        def patients -> Table(PatientsCols, MaybePatientsCols)
          table(
            "patients",
            "patients",
            (a) -> { PatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            (a) -> { MaybePatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            ["id"],
          )
        end


        def add(name: String) -> Task(Int, SqlError)
          insert(NewPatient(name), patients) |> execute
        end


        def all_patients -> Q(Selector(Patient))
          p <- from(patients)
          select(Patient(_, _, _))
            |> field(p.id)
            |> field(p.name)
            |> field(p.balance)
            |> order(p.id)
        end


        def bump(rows: List(Patient)) -> Task(Int, SqlError)
          rows
            |> List.map((r) -> { r.id })
            |> bump_ids
        end


        def bump_ids(ids: List(Int)) -> Task(Int, SqlError)
          Sql.execute_raw(
            (
              "UPDATE patients SET balance = balance + 1 WHERE id = ANY(ARRAY[?])",
              [encode(ids)],
            ),
          )
        end


        def bump_all(size: Int) -> Task(Int, SqlError)
          all_patients |> in_batches(size, bump)
        end


        def count_all_rows -> Task(Int, SqlError)
          fetch_one_raw(("SELECT count(*)::int FROM patients", []))
        end
      JADE
    end

    before { test_compiler.require('app', source) }

    def seed(count)
      count.times { |i| App::Internal.add("p#{i}").run }
    end

    it 'sees every row across pages and reports the total' do
      seed(5)

      expect(App::Internal.bump_all(2).run).to eq Jade::Result::Ok[5]
      expect(conn.select_all('SELECT balance FROM patients').rows.flatten).to all(eq 1)
    end

    it 'reports zero when the query matches nothing' do
      expect(App::Internal.bump_all(10).run).to eq Jade::Result::Ok[0]
    end

    it 'handles a final partial page' do
      seed(7)

      expect(App::Internal.bump_all(3).run).to eq Jade::Result::Ok[7]
      expect(conn.select_all('SELECT balance FROM patients').rows.flatten).to all(eq 1)
    end
  end
end
