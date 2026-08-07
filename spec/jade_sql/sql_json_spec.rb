require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'

module Jade
  describe 'Sql.Json (extension)' do
    include_context 'with test compiler'

    describe 'object/prop/build' do
      it 'renders json_build_object with the props in order' do
        test_compiler.require('app', <<~JADE)
          module App exposing (projection)

          import Sql exposing (Expr, column)
          import Sql.Json as Json exposing (Json)


          struct Row = {
            id: String,
            name: String
          }


          def projection -> Expr(Json(Row))
            Json.object(Row(_, _))
              |> Json.prop("id", column("t", "id"))
              |> Json.prop("name", column("t", "name"))
              |> Json.build
          end
        JADE

        App::Internal.projection.then do |expr|
          expect(expr.sql).to eql(
            "json_build_object('id', t.id, 'name', t.name)",
          )
          expect(expr.params).to eql []
        end
      end

      it 'threads params through in prop order' do
        test_compiler.require('app', <<~JADE)
          module App exposing (projection)

          import Sql exposing (Expr, column, to_expr)
          import Sql.Json as Json exposing (Json)


          struct Row = {
            a: Int,
            b: Int
          }


          def projection -> Expr(Json(Row))
            Json.object(Row(_, _))
              |> Json.prop("a", to_expr(1))
              |> Json.prop("b", to_expr(2))
              |> Json.build
          end
        JADE

        App::Internal.projection.then do |expr|
          expect(expr.sql).to eql "json_build_object('a', ?, 'b', ?)"
          expect(expr.params).to eql [1, 2]
        end
      end
    end

    describe 'agg' do
      it 'renders json_agg with an ORDER BY and stays Maybe' do
        test_compiler.require('app', <<~JADE)
          module App exposing (agg_expr)

          import Sql exposing (Expr, column)
          import Sql.Json as Json exposing (Json)


          struct Row = { id: String }


          def one -> Expr(Json(Row))
            Json.object(Row(_))
              |> Json.prop("id", column("l", "id"))
              |> Json.build
          end


          def agg_expr -> Expr(Maybe(List(Row)))
            Json.agg(one, column("l", "id"))
          end
        JADE

        App::Internal.agg_expr.then do |expr|
          expect(expr.sql).to eql(
            "json_agg(json_build_object('id', l.id) ORDER BY l.id)",
          )
        end
      end

      it 'coalesces to an empty array through Sql.coalesce' do
        test_compiler.require('app', <<~JADE)
          module App exposing (lines_expr)

          import Sql exposing (Expr, coalesce, column)
          import Sql.Json as Json exposing (Json)


          struct Row = { id: String }


          def one -> Expr(Json(Row))
            Json.object(Row(_))
              |> Json.prop("id", column("l", "id"))
              |> Json.build
          end


          def lines_expr -> Expr(List(Row))
            coalesce(Json.agg(one, column("l", "id")), Json.empty_list)
          end
        JADE

        App::Internal.lines_expr.then do |expr|
          expect(expr.sql).to eql(
            "COALESCE(json_agg(json_build_object('id', l.id) " \
            "ORDER BY l.id), '[]'::json)",
          )
        end
      end
    end

    describe 'of_array' do
      it 'wraps a Postgres array so it serializes as a JSON array' do
        test_compiler.require('app', <<~JADE)
          module App exposing (tags)

          import Sql exposing (Expr, column)
          import Sql.Json as Json exposing (Json)


          def tags -> Expr(List(String))
            Json.of_array(column("l", "tags"))
          end
        JADE

        App::Internal.tags.then do |expr|
          expect(expr.sql).to eql 'to_jsonb(l.tags)'
        end
      end
    end


    describe 'select' do
      it 'aliases the projection to Doc\'s field so the row decodes' do
        test_compiler.require('app', <<~JADE)
          module App exposing (q)

          import Sql exposing (Selector, column)
          import Sql.Query as Query exposing (Q)
          import Sql.Json as Json exposing (Doc, Json)


          struct Row = { id: String }


          def one -> Sql.Expr(Json(Row))
            Json.object(Row(_))
              |> Json.prop("id", column("t", "id"))
              |> Json.build
          end


          def q -> Q(Selector(Doc(Row)))
            Json.select(one)
          end
        JADE

        rendered = App::Internal.q.then { Sql::Query::Internal.to_sql(it) }
        sql = rendered._1
        params = rendered._2
        expect(sql).to eql(
          "SELECT json_build_object('id', t.id) AS text",
        )
        expect(params).to eql []
      end

      it 'composes with the filters a domain scope adds afterwards' do
        test_compiler.require('app', <<~JADE)
          module App exposing (q)

          import Sql exposing (Selector, column, eq, to_expr)
          import Sql.Query as Query exposing (Q)
          import Sql.Json as Json exposing (Doc, Json)


          struct Row = { id: String }


          def one -> Sql.Expr(Json(Row))
            Json.object(Row(_))
              |> Json.prop("id", column("t", "id"))
              |> Json.build
          end


          def q -> Q(Selector(Doc(Row)))
            Json.select(one)
              |> Query.where(eq(column("t", "book_id"), to_expr("b1")))
              |> Query.limit(100)
          end
        JADE

        rendered = App::Internal.q.then { Sql::Query::Internal.to_sql(it) }
        sql = rendered._1
        params = rendered._2
        expect(sql).to eql(
          "SELECT json_build_object('id', t.id) AS text " \
          'WHERE t.book_id = ? LIMIT 100',
        )
        expect(params).to eql ['b1']
      end
    end

    describe 'correlated' do
      it 'renders a scalar subquery correlated to the outer columns' do
        test_compiler.require('app', <<~JADE)
          module App exposing (sub)

          import Sql exposing (Expr, Selector, column, eq)
          import Sql.Query as Query exposing (Q)
          import Sql.Json as Json exposing (Json)


          struct Row = { id: String }


          def child(outer: Expr(String)) -> Q(Selector(Int))
            Query.select(identity)
              |> Query.field(Sql.count_all)
              |> Query.where(eq(column("l", "transaction_id"), outer))
          end


          def sub -> Expr(Int)
            Json.correlated(column("t", "id"), child)
          end
        JADE

        App::Internal.sub.then do |expr|
          expect(expr.sql).to eql(
            '(SELECT COUNT(*) WHERE l.transaction_id = t.id)',
          )
        end
      end
    end
  end
end
