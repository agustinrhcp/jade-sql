require 'spec_helper'

require 'json'
require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'Sql.Json against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
        module App exposing (insert_patient, list_json, peers_json, tagged_json)

        import Sql exposing (
          Assignment,
          Expr,
          Selector,
          SqlError,
          SqlMapper,
          Table,
          assign,
          coalesce,
          column,
          execute,
          gt,
          table,
        )
        import Sql.Mutation exposing (insert)
        import Sql.Query as Query exposing (Q)
        import Sql.Json as Json exposing (Doc, Json)


        struct Patient = {
          id: Int,
          name: String,
          balance: Int
        }


        struct Tagged = {
          name: String,
          tags: List(String)
        }


        struct WithPeers = {
          id: Int,
          peers: List(Patient)
        }


        struct NewPatient = {
          name: String,
          balance: Int
        }


        implements SqlMapper(NewPatient) with
          to_assigns: new_patient_assigns
        end


        def new_patient_assigns(p: NewPatient) -> List(Assignment)
          [assign("name", p.name), assign("balance", p.balance)]
        end


        def patients -> Table(c, m)
          table("patients", "p", (a) -> { a }, (a) -> { a }, ["id"])
        end


        # A second handle on the same table under its own alias, so the
        # correlated subquery can reference the outer row without capture.
        def other_patients -> Table(c, m)
          table("patients", "p2", (a) -> { a }, (a) -> { a }, ["id"])
        end


        def insert_patient(name: String, balance: Int) -> Task(Int, SqlError)
          NewPatient(name, balance)
            |> insert(patients)
            |> execute
        end


        def patient_json -> Expr(Json(Patient))
          Json.object(Patient(_, _, _))
            |> Json.prop("id", column("p", "id"))
            |> Json.prop("name", column("p", "name"))
            |> Json.prop("balance", column("p", "balance"))
            |> Json.build
        end


        def list_query -> Q(Selector(Doc(Patient)))
          _ <- Query.from(patients)
          Json.select(patient_json) |> Query.order(column("p", "id"))
        end


        def list_json -> Task(Doc(List(Patient)), SqlError)
          Json.fetch_many(list_query)
        end


        def tagged_query -> Q(Selector(Doc(Tagged)))
          _ <- Query.from(patients)
          Json.select(
            Json.object(Tagged(_, _))
              |> Json.prop("name", column("p", "name"))
              |> Json.prop("tags", Json.of_array(column("p", "tags")))
              |> Json.build,
          )
            |> Query.order(column("p", "id"))
        end


        def tagged_json -> Task(Doc(List(Tagged)), SqlError)
          Json.fetch_many(tagged_query)
        end


        def other_json -> Expr(Json(Patient))
          Json.object(Patient(_, _, _))
            |> Json.prop("id", column("p2", "id"))
            |> Json.prop("name", column("p2", "name"))
            |> Json.prop("balance", column("p2", "balance"))
            |> Json.build
        end


        # json_agg over an empty group is NULL, so `agg` is Maybe and coalesce
        # is the only way to a placeable value.
        def peers -> Expr(Maybe(List(Patient)))
          Json.correlated(
            column("p", "id"),
            (outer) -> {
              _ <- Query.from(other_patients)
              Query.select(identity)
                |> Query.field(Json.agg(other_json, column("p2", "id")))
                |> Query.where(gt(column("p2", "id"), outer))
            },
          )
        end


        def peers_query -> Q(Selector(Doc(WithPeers)))
          _ <- Query.from(patients)
          Json.select(
            Json.object(WithPeers(_, _))
              |> Json.prop("id", column("p", "id"))
              |> Json.prop("peers", coalesce(peers, Json.empty_list))
              |> Json.build,
          )
            |> Query.order(column("p", "id"))
        end


        def peers_json -> Task(Doc(List(WithPeers)), SqlError)
          Json.fetch_many(peers_query)
        end
      JADE
    end

    before { test_compiler.require('app', source) }

    def run!(task)
      case task.run
      in Jade::Result::Ok[v] then v
      in Jade::Result::Err[e] then raise "task failed: #{e.inspect}"
      end
    end

    it 'renders rows as a JSON array of objects' do
      run!(App::Internal.insert_patient('Ann', 10))
      run!(App::Internal.insert_patient('Bob', 20))

      doc = run!(App::Internal.list_json)

      expect(JSON.parse(doc.text)).to eql(
        [
          { 'id' => 1, 'name' => 'Ann', 'balance' => 10 },
          { 'id' => 2, 'name' => 'Bob', 'balance' => 20 },
        ],
      )
    end

    it 'returns an empty array when there are no rows' do
      doc = run!(App::Internal.list_json)

      expect(doc.text).to eql '[]'
      expect(JSON.parse(doc.text)).to eql []
    end

    it 'serializes a Postgres array as a JSON array, not {a,b}' do
      run!(App::Internal.insert_patient('Ann', 10))
      JadeSql::TestDb.connection.execute(
        "UPDATE patients SET tags = '{work,travel}'",
      )

      doc = run!(App::Internal.tagged_json)

      expect(JSON.parse(doc.text))
        .to eql [{ 'name' => 'Ann', 'tags' => %w[work travel] }]
    end

    it 'coalesces an empty correlated json_agg to [] rather than null' do
      run!(App::Internal.insert_patient('Ann', 10))
      run!(App::Internal.insert_patient('Bob', 20))

      rows = JSON.parse(run!(App::Internal.peers_json).text)

      # Ann has Bob after her; Bob has nobody, so his json_agg saw no rows and
      # returned NULL — the case coalesce exists to catch.
      expect(rows.first['peers'])
        .to eql [{ 'id' => 2, 'name' => 'Bob', 'balance' => 20 }]
      expect(rows.last['peers']).to eql []
      expect(rows.last['peers']).not_to be_nil
    end
  end
end
