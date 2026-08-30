require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'

module Jade
  describe 'Sql (extension)' do
    include_context 'with test compiler'

    describe 'column' do
      it 'builds a qualified column reference with no params' do
        test_compiler.require('app', <<~JADE)
          module App exposing (make_col)

          import Sql exposing (Expr, column)


          def make_col -> Expr(a)
            column("p", "name")
          end
        JADE

        App::Internal.make_col.then do |expr|
          expect(expr.sql).to eql 'p.name'
          expect(expr.params).to eql []
        end
      end
    end

    describe 'to_expr (polymorphic via SqlEncodable)' do
      it 'encodes an Int into VInt' do
        test_compiler.require('app', <<~JADE)
          module App exposing (make_expr)

          import Sql exposing (Expr, to_expr)


          def make_expr -> Expr(Int)
            to_expr(42)
          end
        JADE

        App::Internal.make_expr.then do |expr|
          expect(expr.sql).to eql '?'
          expect(expr.params).to eql [42]
        end
      end

      it 'encodes a String into VStr' do
        test_compiler.require('app', <<~JADE)
          module App exposing (make_expr)

          import Sql exposing (Expr, to_expr)


          def make_expr -> Expr(String)
            to_expr("paul")
          end
        JADE

        App::Internal.make_expr.then do |expr|
          expect(expr.params).to eql ['paul']
        end
      end

      it 'encodes Just(n) recursively as VInt' do
        test_compiler.require('app', <<~JADE)
          module App exposing (make_expr)

          import Sql exposing (Expr, to_expr)


          def make_expr -> Expr(Maybe(Int))
            to_expr(Just(12))
          end
        JADE

        App::Internal.make_expr.then do |expr|
          expect(expr.params).to eql [12]
        end
      end

      it 'encodes Nothing as VNull' do
        test_compiler.require('app', <<~JADE)
          module App exposing (make_expr)

          import Sql exposing (Expr, to_expr)


          def make_expr -> Expr(Maybe(Int))
            to_expr(Nothing)
          end
        JADE

        App::Internal.make_expr.then do |expr|
          expect(expr.params).to eql [nil]
        end
      end
    end

    describe 'eq' do
      it 'merges sql and params, in order' do
        test_compiler.require('app', <<~JADE)
          module App exposing (predicate)

          import Sql exposing (Expr, column, eq, to_expr)


          def predicate -> Expr(Bool)
            column("p", "age") |> eq(to_expr(18))
          end
        JADE

        App::Internal.predicate.then do |expr|
          expect(expr.sql).to eql 'p.age = ?'
          expect(expr.params).to eql [18]
        end
      end
    end

    describe 'comparison operators' do
      it 'render >, >=, <, <= against the DB clock and params' do
        test_compiler.require('app', <<~JADE)
          module App exposing (after_now, at_least, at_most, cheap)

          import Sql exposing (Expr, column, gt, gte, lt, lte, now, to_expr)


          def after_now -> Expr(Bool)
            column("s", "expires_at") |> gt(now)
          end


          def at_least -> Expr(Bool)
            column("t", "amount") |> gte(to_expr(100))
          end


          def cheap -> Expr(Bool)
            column("t", "amount") |> lt(to_expr(5))
          end


          def at_most -> Expr(Bool)
            column("t", "amount") |> lte(to_expr(5))
          end
        JADE

        App::Internal.after_now.then do |expr|
          expect(expr.sql).to eql 's.expires_at > now()'
          expect(expr.params).to eql []
        end
        App::Internal.at_least.then do |expr|
          expect(expr.sql).to eql 't.amount >= ?'
          expect(expr.params).to eql [100]
        end
        expect(App::Internal.cheap.sql).to eql 't.amount < ?'
        expect(App::Internal.at_most.sql).to eql 't.amount <= ?'
      end
    end

    describe 'is_null' do
      it 'appends IS NULL' do
        test_compiler.require('app', <<~JADE)
          module App exposing (predicate)

          import Sql exposing (Expr, column, is_null)


          def predicate -> Expr(Bool)
            column("p", "age") |> is_null
          end
        JADE

        App::Internal.predicate.then do |expr|
          expect(expr.sql).to eql 'p.age IS NULL'
          expect(expr.params).to eql []
        end
      end
    end

    describe 'and' do
      it 'joins predicates with AND' do
        test_compiler.require('app', <<~JADE)
          module App exposing (predicate)

          import Sql exposing (Expr, and, column, eq, to_expr)


          def predicate -> Expr(Bool)
            a = column("p", "a") |> eq(to_expr(1))
            b = column("p", "b") |> eq(to_expr(2))
            a |> and(b)
          end
        JADE

        App::Internal.predicate.then do |expr|
          expect(expr.sql).to eql 'p.a = ? AND p.b = ?'
          expect(expr.params).to eql [1, 2]
        end
      end
    end

    describe 'or' do
      it 'joins predicates with OR, parenthesised' do
        test_compiler.require('app', <<~JADE)
          module App exposing (predicate)

          import Sql exposing (Expr, column, eq, or, to_expr)


          def predicate -> Expr(Bool)
            a = column("p", "a") |> eq(to_expr(1))
            b = column("p", "b") |> eq(to_expr(2))
            a |> or(b)
          end
        JADE

        App::Internal.predicate.then do |expr|
          expect(expr.sql).to eql '(p.a = ? OR p.b = ?)'
          expect(expr.params).to eql [1, 2]
        end
      end

      # `where` joins its predicates with AND, so an unparenthesised OR would
      # bind as `(x = ? AND a) OR b` and quietly widen the result set.
      it 'survives being ANDed by where' do
        test_compiler.require('app', <<~JADE)
          module App exposing (predicate)

          import Sql exposing (Expr, and, column, eq, or, to_expr)


          def predicate -> Expr(Bool)
            x = column("p", "x") |> eq(to_expr(0))
            a = column("p", "a") |> eq(to_expr(1))
            b = column("p", "b") |> eq(to_expr(2))
            x |> and(or(a, b))
          end
        JADE

        App::Internal.predicate.then do |expr|
          expect(expr.sql).to eql 'p.x = ? AND (p.a = ? OR p.b = ?)'
          expect(expr.params).to eql [0, 1, 2]
        end
      end
    end

    describe 'cast' do
      it 'rewraps the phantom type without touching sql or params' do
        test_compiler.require('app', <<~JADE)
          module App exposing (recast)

          import Sql exposing (Expr, cast, column)


          def recast -> Expr(Bool)
            column("p", "kind") |> cast
          end
        JADE

        App::Internal.recast.then do |expr|
          expect(expr.sql).to eql 'p.kind'
          expect(expr.params).to eql []
        end
      end
    end

    describe 'aggregates / coalesce / neg' do
      let(:source) do
        <<~JADE
          module App exposing (
            coalesced,
            count_col,
            count_star,
            negated,
            sum_col,
          )

          import Sql exposing (
            Expr,
            Pk,
            coalesce,
            column,
            count,
            count_all,
            neg,
            sum,
            to_expr,
          )


          def sum_col -> Expr(Maybe(Int))
            column("p", "amount") |> sum
          end


          def count_col -> Expr(Int)
            column("p", "id") |> count
          end


          def count_star -> Expr(Int)
            count_all
          end


          def coalesced -> Expr(Int)
            coalesce(sum(column("p", "amount")), to_expr(0))
          end


          def negated -> Expr(Int)
            column("p", "amount") |> neg
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'sum wraps a column' do
        App::Internal.sum_col.then do |expr|
          expect(expr.sql).to eql 'SUM(p.amount)'
          expect(expr.params).to eql []
        end
      end

      it 'count and count_all' do
        App::Internal.count_col.then { |e| expect(e.sql).to eql 'COUNT(p.id)' }
        App::Internal.count_star.then { |e| expect(e.sql).to eql 'COUNT(*)' }
      end

      it 'coalesce wraps a Maybe expr with a default' do
        App::Internal.coalesced.then do |expr|
          expect(expr.sql).to eql 'COALESCE(SUM(p.amount), ?)'
          expect(expr.params).to eql [0]
        end
      end

      it 'neg negates an Int expr' do
        App::Internal.negated.then { |e| expect(e.sql).to eql '-(p.amount)' }
      end
    end

    describe 'array predicates' do
      let(:source) do
        <<~JADE
          module App exposing (
            any_tag,
            both_tags,
            has_tag,
            no_extra_tags,
            tag_count,
          )

          import Sql exposing (
            Expr,
            array_contained_by,
            array_contains,
            array_has,
            array_length,
            array_overlaps,
            column,
          )


          def any_tag(tags: List(String)) -> Expr(Bool)
            array_overlaps(column("l", "tags"), tags)
          end


          def has_tag(tag: String) -> Expr(Bool)
            array_has(column("l", "tags"), tag)
          end


          def both_tags(tags: List(String)) -> Expr(Bool)
            array_contains(column("l", "tags"), tags)
          end


          def no_extra_tags(allowed: List(String)) -> Expr(Bool)
            array_contained_by(column("l", "tags"), allowed)
          end


          def tag_count -> Expr(Int)
            array_length(column("l", "tags"))
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'array_overlaps emits col && ? with the list bound as one param' do
        App::Internal.any_tag(["food", "fun"]).then do |expr|
          expect(expr.sql).to eql 'l.tags && ?'
          expect(expr.params).to eql [["food", "fun"]]
        end
      end

      it 'array_overlaps binds an empty list as a single empty-array param' do
        App::Internal.any_tag([]).then do |expr|
          expect(expr.sql).to eql 'l.tags && ?'
          expect(expr.params).to eql [[]]
        end
      end

      it 'array_has emits ? = ANY(col) with the value before the column params' do
        App::Internal.has_tag("food").then do |expr|
          expect(expr.sql).to eql '? = ANY(l.tags)'
          expect(expr.params).to eql ["food"]
        end
      end

      it 'array_contains emits col @> ?' do
        App::Internal.both_tags(["food", "fun"]).then do |expr|
          expect(expr.sql).to eql 'l.tags @> ?'
          expect(expr.params).to eql [["food", "fun"]]
        end
      end

      it 'array_contained_by emits col <@ ?' do
        App::Internal.no_extra_tags(["food", "fun"]).then do |expr|
          expect(expr.sql).to eql 'l.tags <@ ?'
          expect(expr.params).to eql [["food", "fun"]]
        end
      end

      it 'array_length emits cardinality(col)' do
        App::Internal.tag_count.then do |expr|
          expect(expr.sql).to eql 'cardinality(l.tags)'
          expect(expr.params).to eql []
        end
      end
    end

    describe 'array mutation ops' do
      let(:source) do
        <<~JADE
          module App exposing (added, concat_, removed)

          import Sql exposing (
            Expr,
            array_append,
            array_concat,
            array_remove,
            column,
            to_expr,
          )


          def added(tag: String) -> Expr(List(String))
            array_append(column("l", "tags"), tag)
          end


          def removed(tag: String) -> Expr(List(String))
            array_remove(column("l", "tags"), tag)
          end


          def concat_(extra: List(String)) -> Expr(List(String))
            array_concat(column("l", "tags"), to_expr(extra))
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'array_append wraps array_append(col, ?)' do
        App::Internal.added("food").then do |expr|
          expect(expr.sql).to eql 'array_append(l.tags, ?)'
          expect(expr.params).to eql ['food']
        end
      end

      it 'array_remove wraps array_remove(col, ?)' do
        App::Internal.removed("food").then do |expr|
          expect(expr.sql).to eql 'array_remove(l.tags, ?)'
          expect(expr.params).to eql ['food']
        end
      end

      it 'array_concat emits left || right' do
        App::Internal.concat_(["food", "fun"]).then do |expr|
          expect(expr.sql).to eql 'l.tags || ?'
          expect(expr.params).to eql [["food", "fun"]]
        end
      end
    end

    describe 'jsonb predicates' do
      let(:source) do
        <<~JADE
          module App exposing (has_kind, has_path, kind_matcher)

          import Decode exposing (Value)
          import Sql exposing (
            Expr,
            column,
            jsonb_contains,
            jsonb_path_exists,
          )


          struct KindFilter = { kind: String }


          def has_kind(k: String) -> Expr(Bool)
            jsonb_contains(column("r", "match"), KindFilter(k))
          end


          def kind_matcher -> Expr(Bool)
            jsonb_contains(column("r", "match"), KindFilter("income"))
          end


          def has_path(p: String) -> Expr(Bool)
            jsonb_path_exists(column("r", "match"), p)
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'jsonb_contains encodes the value as JSON' do
        App::Internal.has_kind("income").then do |expr|
          expect(expr.sql).to eql 'r.match @> ?'
          expect(expr.params).to eql [{ "kind" => "income" }]
        end
      end

      it 'jsonb_contains accepts struct literals' do
        App::Internal.kind_matcher.then do |expr|
          expect(expr.sql).to eql 'r.match @> ?'
          expect(expr.params).to eql [{ "kind" => "income" }]
        end
      end

      it 'jsonb_path_exists casts the path to jsonpath' do
        App::Internal.has_path("$.kind ? (@ == \"income\")").then do |expr|
          expect(expr.sql).to eql 'r.match @? ?::jsonpath'
          expect(expr.params).to eql ['$.kind ? (@ == "income")']
        end
      end
    end

    describe 'from + where via postfix' do
      let(:source) do
        <<~JADE
          module App exposing (named_paul)

          import Sql exposing (
            Expr,
            NoJoins,
            Pk,
            Table,
            column,
            columns,
            eq,
            no_joins,
            pk,
            table,
            to_expr,
          )
          import Encode
          import Sql.Query exposing (Q, from, where)


          struct PersonsCols = {
            id: Expr(Int),
            name: Expr(String)
          }


          struct MaybePersonsCols = {
            id: Expr(Maybe(Int)),
            name: Expr(Maybe(String))
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id"), column(a, "name")) },
              (a) -> { MaybePersonsCols(column(a, "id"), column(a, "name")) },
              persons_pk,
              no_joins,
            )
          end


          def named_paul -> Q(PersonsCols)
            p_cols = columns(persons, "p")
            from(persons) |> where(p_cols.name |> eq(to_expr("Paul")))
          end
        JADE
      end

      it 'records the table and where clause' do
        test_compiler.require('app', source)

        App::Internal.named_paul.then do |q|
          expect(q.tables.size).to eql 1
          expect(q.tables.first.name).to eql 'persons'
          expect(q.tables.first.alias_).to eql 'p'
          expect(q.wheres.size).to eql 1
          expect(q.wheres.first.sql).to eql 'p.name = ?'
          expect(q.wheres.first.params).to eql ['Paul']
        end
      end
    end

    describe 'inner join via bind chain' do
      let(:source) do
        <<~JADE
          module App exposing (persons_with_orders)

          import Sql exposing (Expr, NoJoins, Pk, Table, column, eq, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (Q, from, join)


          struct PersonsCols = { id: Expr(Int) }


          struct MaybePersonsCols = { id: Expr(Maybe(Int)) }


          struct OrdersCols = {
            id: Expr(Int),
            person_id: Expr(Int)
          }


          struct MaybeOrdersCols = {
            id: Expr(Maybe(Int)),
            person_id: Expr(Maybe(Int))
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id")) },
              (a) -> { MaybePersonsCols(column(a, "id")) },
              persons_pk,
              no_joins,
            )
          end


          def orders_pk -> Pk(OrdersCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def orders -> Table(OrdersCols, MaybeOrdersCols, Int, NoJoins)
            table(
              "orders",
              "o",
              (a) -> { OrdersCols(column(a, "id"), column(a, "person_id")) },
              (a) -> { MaybeOrdersCols(column(a, "id"), column(a, "person_id")) },
              orders_pk,
              no_joins,
            )
          end


          def persons_with_orders -> Q(OrdersCols)
            p <- from(persons)
            join(orders, (o) -> { p.id |> eq(o.person_id) })
          end
        JADE
      end

      it 'records the inner join with predicate' do
        test_compiler.require('app', source)

        App::Internal.persons_with_orders.then do |q|
          expect(q.tables.size).to eql 1
          expect(q.tables.first.name).to eql 'persons'
          expect(q.joins.size).to eql 1
          j = q.joins.first
          expect(j.kind).to eql Sql::Query::InnerJ[]
          expect(j.name).to eql 'orders'
          expect(j.alias_).to eql 'o'
          expect(j.on.sql).to eql 'p.id = o.person_id'
        end
      end
    end

    describe 'aliased — self-join with explicit alias' do
      let(:source) do
        <<~JADE
          module App exposing (parents_and_kids)

          import Sql exposing (Expr, NoJoins, Pk, Table, aliased, column, eq, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (Q, from, join)


          struct PersonsCols = {
            id: Expr(Int),
            parent_id: Expr(Int)
          }


          struct MaybePersonsCols = {
            id: Expr(Maybe(Int)),
            parent_id: Expr(Maybe(Int))
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "persons",
              (a) -> { PersonsCols(column(a, "id"), column(a, "parent_id")) },
              (a) -> { MaybePersonsCols(column(a, "id"), column(a, "parent_id")) },
              persons_pk,
              no_joins,
            )
          end


          def parents_and_kids -> Q(PersonsCols)
            p <- from(persons)
            persons
              |> aliased("c")
              |> join((c) -> { p.id |> eq(c.parent_id) })
          end
        JADE
      end

      it 'overrides the join alias and qualifies its columns' do
        test_compiler.require('app', source)

        App::Internal.parents_and_kids.then do |q|
          expect(q.tables.first.alias_).to eql 'persons'
          expect(q.joins.size).to eql 1
          j = q.joins.first
          expect(j.name).to eql 'persons'
          expect(j.alias_).to eql 'c'
          expect(j.on.sql).to eql 'persons.id = c.parent_id'
        end
      end
    end

    describe 'left_join via bind chain' do
      let(:source) do
        <<~JADE
          module App exposing (persons_with_optional_orders)

          import Sql exposing (Expr, NoJoins, Pk, Table, column, eq, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (Q, from, left_join)


          struct PersonsCols = { id: Expr(Int) }


          struct MaybePersonsCols = { id: Expr(Maybe(Int)) }


          struct OrdersCols = {
            id: Expr(Int),
            person_id: Expr(Int)
          }


          struct MaybeOrdersCols = {
            id: Expr(Maybe(Int)),
            person_id: Expr(Maybe(Int))
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id")) },
              (a) -> { MaybePersonsCols(column(a, "id")) },
              persons_pk,
              no_joins,
            )
          end


          def orders_pk -> Pk(OrdersCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def orders -> Table(OrdersCols, MaybeOrdersCols, Int, NoJoins)
            table(
              "orders",
              "o",
              (a) -> { OrdersCols(column(a, "id"), column(a, "person_id")) },
              (a) -> { MaybeOrdersCols(column(a, "id"), column(a, "person_id")) },
              orders_pk,
              no_joins,
            )
          end


          def persons_with_optional_orders -> Q(MaybeOrdersCols)
            p <- from(persons)
            left_join(orders, (o) -> { p.id |> eq(o.person_id) })
          end
        JADE
      end

      it 'records left_join with strict on-predicate, maybe result' do
        test_compiler.require('app', source)

        App::Internal.persons_with_optional_orders.then do |q|
          j = q.joins.first
          expect(j.kind).to eql Sql::Query::LeftJ[]
          expect(j.on.sql).to eql 'p.id = o.person_id'
        end
      end
    end

    describe 'inner join on a nullable FK requires nullable() lift' do
      let(:source) do
        <<~JADE
          module App exposing (persons_with_companies)

          import Sql exposing (Expr, NoJoins, Pk, Table, column, eq, no_joins, nullable, pk, table)
          import Encode
          import Sql.Query exposing (Q, from, join)


          struct PersonsCols = {
            id: Expr(Int),
            company_id: Expr(Maybe(Int))
          }


          struct MaybePersonsCols = {
            id: Expr(Maybe(Int)),
            company_id: Expr(Maybe(Int))
          }


          struct CompaniesCols = { id: Expr(Int) }


          struct MaybeCompaniesCols = { id: Expr(Maybe(Int)) }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id"), column(a, "company_id")) },
              (a) -> { MaybePersonsCols(column(a, "id"), column(a, "company_id")) },
              persons_pk,
              no_joins,
            )
          end


          def companies_pk -> Pk(CompaniesCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def companies -> Table(CompaniesCols, MaybeCompaniesCols, Int, NoJoins)
            table(
              "companies",
              "c",
              (a) -> { CompaniesCols(column(a, "id")) },
              (a) -> { MaybeCompaniesCols(column(a, "id")) },
              companies_pk,
              no_joins,
            )
          end


          def persons_with_companies -> Q(CompaniesCols)
            p <- from(persons)
            join(companies, (c) -> { p.company_id |> eq(c.id |> nullable) })
          end
        JADE
      end

      it 'compiles when c.id is lifted to Maybe(Int)' do
        test_compiler.require('app', source)

        App::Internal.persons_with_companies.then do |q|
          j = q.joins.first
          expect(j.on.sql).to eql 'p.company_id = c.id'
        end
      end
    end

    describe 'select pipeline via bind chain (waits for placeholders)' do
      let(:adults_source) do
        <<~JADE
module App exposing (adults_query)

import Sql exposing (
  Expr,
  NoJoins,
  Pk,
  Selector,
  Table,
  column,
  eq,
  no_joins,
  pk,
  table,
  to_expr,
)
import Encode
import Sql.Query exposing (Q, field, from, select, where)


struct PersonsCols = {
  id: Expr(Int),
  name: Expr(String),
  age: Expr(Int)
}


struct MaybePersonsCols = {
  id: Expr(Maybe(Int)),
  name: Expr(Maybe(String)),
  age: Expr(Maybe(Int))
}


struct Person = {
  id: Int,
  name: String,
  age: Int
}


def persons_pk -> Pk(PersonsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
  table(
    "persons",
    "p",
    (a) -> { PersonsCols(column(a, "id"), column(a, "name"), column(a, "age")) },
    (a) -> { MaybePersonsCols(column(a, "id"), column(a, "name"), column(a, "age")) },
    persons_pk,
    no_joins,
  )
end


def adults_query -> Q(Selector(Person))
  p <- from(persons)
  select(Person(_, _, _))
    |> field(p.id)
    |> field(p.name)
    |> field(p.age)
end
        JADE
      end

      it 'projects the selected columns in declared order' do
        test_compiler.require('app', adults_source)

        App::Internal.adults_query.then do |q|
          expect(q.result.columns_sql).to eql ['p.id', 'p.name', 'p.age']
        end
      end
    end

    describe 'to_sql renders joined queries with params in clause order' do
      let(:source) do
        <<~JADE
module App exposing (rendered)

import Sql exposing (
  Expr,
  NoJoins,
  Pk,
  Selector,
  Table,
  column,
  eq,
  is_not_null,
  no_joins,
  pk,
  table,
  to_expr,
)
import Encode
import Sql.Query exposing (Q, field, from, join, select, to_sql, where)
import Decode exposing (Value)


struct PersonsCols = {
  id: Expr(Int),
  name: Expr(String),
  age: Expr(Maybe(Int))
}


struct MaybePersonsCols = {
  id: Expr(Maybe(Int)),
  name: Expr(Maybe(String)),
  age: Expr(Maybe(Int))
}


struct OrdersCols = {
  id: Expr(Int),
  person_id: Expr(Int),
  total: Expr(Int)
}


struct MaybeOrdersCols = {
  id: Expr(Maybe(Int)),
  person_id: Expr(Maybe(Int)),
  total: Expr(Maybe(Int))
}


struct Row = {
  id: Int,
  name: String,
  total: Int
}


def persons_pk -> Pk(PersonsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
  table(
    "persons",
    "p",
    (a) -> { PersonsCols(column(a, "id"), column(a, "name"), column(a, "age")) },
    (a) -> { MaybePersonsCols(column(a, "id"), column(a, "name"), column(a, "age")) },
    persons_pk,
    no_joins,
  )
end


def orders_pk -> Pk(OrdersCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def orders -> Table(OrdersCols, MaybeOrdersCols, Int, NoJoins)
  table(
    "orders",
    "o",
    (a) -> { OrdersCols(column(a, "id"), column(a, "person_id"), column(a, "total")) },
    (a) -> { MaybeOrdersCols(column(a, "id"), column(a, "person_id"), column(a, "total")) },
    orders_pk,
    no_joins,
  )
end


def query -> Q(Selector(Row))
  p <- from(persons)
  o <- join(orders, (o) -> { p.id |> eq(o.person_id) })
  select(Row(_, _, _))
    |> field(p.id)
    |> field(p.name)
    |> field(o.total)
    |> where(p.age |> is_not_null)
    |> where(o.total |> eq(to_expr(100)))
end


def rendered -> (String, List(Value))
  query |> to_sql
end
        JADE
      end

      it 'emits SELECT, FROM, INNER JOIN, WHERE clauses + params in order' do
        test_compiler.require('app', source)

        sql, params = App::Internal.rendered.then { [it._1, it._2] }

        expect(sql).to eql(
          'SELECT p.id, p.name, o.total ' \
          'FROM persons p ' \
          'INNER JOIN orders o ON p.id = o.person_id ' \
          'WHERE p.age IS NOT NULL AND o.total = ?'
        )
        expect(params).to eql [100]
      end
    end

    describe 'field_as renders an AS alias in the projection' do
      let(:source) do
        <<~JADE
          module App exposing (rendered)

          import Sql exposing (Expr, NoJoins, Pk, Selector, Table, column, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (Q, field_as, from, select, to_sql)
          import Decode exposing (Value)


          struct EntriesCols = {
            id: Expr(Int),
            type_: Expr(String)
          }


          struct MaybeEntriesCols = {
            id: Expr(Maybe(Int)),
            type_: Expr(Maybe(String))
          }


          struct Row = {
            id: Int,
            type_: String
          }


          def entries_pk -> Pk(EntriesCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def entries -> Table(EntriesCols, MaybeEntriesCols, Int, NoJoins)
            table(
              "entries",
              "e",
              (a) -> { EntriesCols(column(a, "id"), column(a, "type")) },
              (a) -> { MaybeEntriesCols(column(a, "id"), column(a, "type")) },
              entries_pk,
              no_joins,
            )
          end


          def query -> Q(Selector(Row))
            c <- from(entries)
            select(Row(_, _))
              |> field_as(c.id, "id")
              |> field_as(c.type_, "type_")
          end


          def rendered -> (String, List(Value))
            query |> to_sql
          end
        JADE
      end

      it 'aliases the projected column to the given name' do
        test_compiler.require('app', source)

        expect(App::Internal.rendered._1)
          .to eql('SELECT e.id AS id, e.type AS type_ FROM entries e')
      end
    end

    describe 'order and group for sorting and grouping' do
      let(:source) do
        <<~JADE
          module App exposing (
            grouped,
            multi_sorted,
            sorted_asc,
            sorted_desc,
            sorted_then_paged,
          )

          import Sql exposing (Expr, NoJoins, Pk, Selector, Table, column, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (
            Q,
            field,
            from,
            group,
            limit,
            offset,
            order,
            order_desc,
            select,
            to_sql,
          )
          import Decode exposing (Value)


          struct PersonsCols = {
            id: Expr(Int),
            name: Expr(String),
            age: Expr(Int)
          }


          struct MaybePersonsCols = {
            id: Expr(Maybe(Int)),
            name: Expr(Maybe(String)),
            age: Expr(Maybe(Int))
          }


          struct Person = {
            id: Int,
            name: String,
            age: Int
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id"), column(a, "name"), column(a, "age")) },
              (a) -> { MaybePersonsCols(
                column(a, "id"),
                column(a, "name"),
                column(a, "age"),
              ) },
              persons_pk,
              no_joins,
            )
          end


          def projected -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.age)
          end


          def sorted_asc_q -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.age)
              |> order(p.name)
          end


          def sorted_desc_q -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.age)
              |> order_desc(p.age)
          end


          def multi_sorted_q -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.age)
              |> order_desc(p.age)
              |> order(p.name)
          end


          def grouped_q -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.age)
              |> group(p.age)
              |> group(p.name)
          end


          def sorted_asc -> (String, List(Value))
            sorted_asc_q |> to_sql
          end


          def sorted_desc -> (String, List(Value))
            sorted_desc_q |> to_sql
          end


          def multi_sorted -> (String, List(Value))
            multi_sorted_q |> to_sql
          end


          def grouped -> (String, List(Value))
            grouped_q |> to_sql
          end


          def sorted_then_paged -> (String, List(Value))
            projected
              |> order_desc(column("p", "id"))
              |> limit(10)
              |> offset(20)
              |> to_sql
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'appends ORDER BY with implicit ASC' do
        sql, _ = App::Internal.sorted_asc.then { [it._1, it._2] }
        expect(sql).to eql(
          'SELECT p.id, p.name, p.age FROM persons p ORDER BY p.name'
        )
      end

      it 'appends ORDER BY ... DESC' do
        sql, _ = App::Internal.sorted_desc.then { [it._1, it._2] }
        expect(sql).to eql(
          'SELECT p.id, p.name, p.age FROM persons p ORDER BY p.age DESC'
        )
      end

      it 'preserves order-by declaration order across mixed directions' do
        sql, _ = App::Internal.multi_sorted.then { [it._1, it._2] }
        expect(sql).to eql(
          'SELECT p.id, p.name, p.age FROM persons p ORDER BY p.age DESC, p.name'
        )
      end

      it 'appends GROUP BY with comma-separated columns' do
        sql, _ = App::Internal.grouped.then { [it._1, it._2] }
        expect(sql).to eql(
          'SELECT p.id, p.name, p.age FROM persons p GROUP BY p.age, p.name'
        )
      end

      it 'renders ORDER BY before LIMIT/OFFSET' do
        sql, _ = App::Internal.sorted_then_paged.then { [it._1, it._2] }
        expect(sql).to eql(
          'SELECT p.id, p.name, p.age ' \
          'FROM persons p ' \
          'ORDER BY p.id DESC ' \
          'LIMIT 10 OFFSET 20'
        )
      end
    end

    describe 'limit and offset for pagination' do
      let(:source) do
        <<~JADE
          module App exposing (no_paging, only_offset, page_one, page_two)

          import Sql exposing (Expr, NoJoins, Pk, Selector, Table, column, no_joins, pk, table)
          import Encode
          import Sql.Query exposing (Q, field, from, limit, offset, select, to_sql)
          import Decode exposing (Value)


          struct PersonsCols = {
            id: Expr(Int),
            name: Expr(String)
          }


          struct MaybePersonsCols = {
            id: Expr(Maybe(Int)),
            name: Expr(Maybe(String))
          }


          struct Person = {
            id: Int,
            name: String
          }


          def persons_pk -> Pk(PersonsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def persons -> Table(PersonsCols, MaybePersonsCols, Int, NoJoins)
            table(
              "persons",
              "p",
              (a) -> { PersonsCols(column(a, "id"), column(a, "name")) },
              (a) -> { MaybePersonsCols(column(a, "id"), column(a, "name")) },
              persons_pk,
              no_joins,
            )
          end


          def projected -> Q(Selector(Person))
            p <- from(persons)
            select(Person(_, _))
              |> field(p.id)
              |> field(p.name)
          end


          def page_one -> (String, List(Value))
            projected
              |> limit(10)
              |> to_sql
          end


          def page_two -> (String, List(Value))
            projected
              |> limit(10)
              |> offset(10)
              |> to_sql
          end


          def only_offset -> (String, List(Value))
            projected
              |> offset(20)
              |> to_sql
          end


          def no_paging -> (String, List(Value))
            projected |> to_sql
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'appends LIMIT after WHERE' do
        sql, params = App::Internal.page_one.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT p.id, p.name FROM persons p LIMIT 10'
        expect(params).to eql []
      end

      it 'appends LIMIT then OFFSET' do
        sql, params = App::Internal.page_two.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT p.id, p.name FROM persons p LIMIT 10 OFFSET 10'
        expect(params).to eql []
      end

      it 'appends only OFFSET when LIMIT is unset' do
        sql, _ = App::Internal.only_offset.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT p.id, p.name FROM persons p OFFSET 20'
      end

      it 'emits no LIMIT/OFFSET when neither is set' do
        sql, _ = App::Internal.no_paging.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT p.id, p.name FROM persons p'
      end
    end

    describe 'codec-driven mutations' do
      let(:source) do
        <<~JADE
          module App exposing (
            delete_archived,
            delete_paul,
            delete_paul_returning,
            insert_from_assigns,
            insert_many,
            insert_paul,
            insert_paul_returning,
            rename_paul,
            update_all_nothing,
            update_all_nothing_returning,
            update_all_to_zero,
            update_many_balances,
            update_paul,
            update_paul_returning,
          )

          import Sql exposing (
            Assignable,
            Assignment(..),
            Expr,
            NoJoins,
            Pk,
            Selector,
            Table,
            assign,
            column,
            eq,
            no_joins,
            pk,
            set_,
            table,
            to_assigns,
            to_expr,
          )
          import Sql.Query exposing (Q, field, select)
          import Sql.Mutation exposing (
            Mutation,
            delete,
            delete_all,
            insert,
            insert_all,
            returning,
            to_sql,
            update,
            update_all,
          )
          import Decode exposing (Value)
          import Encode


          struct PatientsCols = {
            id: Expr(Int),
            name: Expr(String),
            balance: Expr(Int),
            archived: Expr(Bool)
          }


          struct MaybePatientsCols = {
            id: Expr(Maybe(Int)),
            name: Expr(Maybe(String)),
            balance: Expr(Maybe(Int)),
            archived: Expr(Maybe(Bool))
          }


          struct Patient = {
            id: Int,
            name: String,
            balance: Int
          }


          struct NewPatient = {
            name: String,
            balance: Int
          }


          struct Rename = { name: String }


          implements Assignable(Rename) with
            to_assigns: encode_rename
          end


          def encode_rename(r: Rename) -> List(Assignment)
            [assign("name", r.name)]
          end


          implements Assignable(NewPatient) with
            to_assigns: encode_new_patient
          end


          def encode_new_patient(p: NewPatient) -> List(Assignment)
            [assign("name", p.name), assign("balance", p.balance)]
          end


          def patients_pk -> Pk(PatientsCols, Int)
            pk(["id"], (v) -> { [Encode.encode(v)] })
          end


          def patients -> Table(PatientsCols, MaybePatientsCols, Int, NoJoins)
            table(
              "patients",
              "p",
              (a) -> { PatientsCols(
                column(a, "id"),
                column(a, "name"),
                column(a, "balance"),
                column(a, "archived"),
              ) },
              (a) -> { MaybePatientsCols(
                column(a, "id"),
                column(a, "name"),
                column(a, "balance"),
                column(a, "archived"),
              ) },
              patients_pk,
              no_joins,
            )
          end


          implements Assignable(Patient) with
            to_assigns: encode_patient
          end


          def encode_patient(p: Patient) -> List(Assignment)
            [
              assign("id", p.id),
              assign("name", p.name),
              assign("balance", p.balance),
            ]
          end


          def insert_paul -> (String, List(Value))
            NewPatient("Paul", 100)
              |> insert(patients)
              |> to_sql
          end


          def insert_from_assigns -> (String, List(Value))
            [assign("name", "Paul"), assign("balance", 100)]
              |> insert(patients)
              |> to_sql
          end


          def rename_paul -> (String, List(Value))
            Rename("Saul")
              |> update(patients, 42)
              |> to_sql
          end


          def update_paul -> (String, List(Value))
            Patient(42, "Paul", 100)
              |> update(patients, 42)
              |> to_sql
          end


          def delete_paul -> (String, List(Value))
            delete(patients, 42) |> to_sql
          end


          def insert_many -> (String, List(Value))
            [NewPatient("Paul", 100), NewPatient("Frank", 200)]
              |> insert_all(patients)
              |> to_sql
          end


          def update_all_nothing -> (String, List(Value))
            patients
              |> update_all(
            (p) -> { p.balance |> eq(to_expr(0)) },
            (p) -> { [] },
          )
              |> to_sql
          end


          def update_all_nothing_returning -> (String, List(Value))
            patients
              |> update_all(
            (p) -> { p.balance |> eq(to_expr(0)) },
            (p) -> { [] },
          )
              |> returning(
            (p) -> { select(Patient(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.balance) },
          )
              |> to_sql
          end


          def update_all_to_zero -> (String, List(Value))
            patients
              |> update_all(
            (p) -> { p.balance |> eq(to_expr(0)) },
            (p) -> { [p.archived |> set_(to_expr(True))] },
          )
              |> to_sql
          end


          def update_many_balances -> (String, List(Value))
            [
              (1, Patient(1, "Ada", 10)),
              (2, Patient(2, "Grace", 20)),
            ]
              |> Sql.Mutation.update_many(patients)
              |> to_sql
          end


          def delete_archived -> (String, List(Value))
            patients
              |> delete_all((p) -> { p.archived |> eq(to_expr(True)) })
              |> to_sql
          end


          def insert_paul_returning -> (String, List(Value))
            NewPatient("Paul", 100)
              |> insert(patients)
              |> returning(
            (p) -> { select(Patient(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.balance) },
          )
              |> to_sql
          end


          def update_paul_returning -> (String, List(Value))
            Patient(42, "Paul", 100)
              |> update(patients, 42)
              |> returning(
            (p) -> { select(Patient(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.balance) },
          )
              |> to_sql
          end


          def delete_paul_returning -> (String, List(Value))
            delete(patients, 42)
              |> returning(
            (p) -> { select(Patient(_, _, _))
              |> field(p.id)
              |> field(p.name)
              |> field(p.balance) },
          )
              |> to_sql
          end
        JADE
      end

      before { test_compiler.require('app', source) }

      it 'insert renders INSERT with codec-driven assigns' do
        sql, params = App::Internal.insert_paul.then { [it._1, it._2] }
        expect(sql).to eql 'INSERT INTO patients (name, balance) VALUES (?, ?)'
        expect(params).to eql ['Paul', 100]
      end

      it 'insert accepts a raw List(Assignment) via Assignable(List(Assignment))' do
        sql, params = App::Internal.insert_from_assigns.then { [it._1, it._2] }
        expect(sql).to eql 'INSERT INTO patients (name, balance) VALUES (?, ?)'
        expect(params).to eql ['Paul', 100]
      end

      it 'update renders UPDATE … WHERE pk = ?' do
        sql, params = App::Internal.update_paul.then { [it._1, it._2] }
        expect(sql).to eql 'UPDATE patients SET name = ?, balance = ? WHERE id = ?'
        expect(params).to eql ['Paul', 100, 42]
      end

      it 'updates from a patch that carries no key of its own' do
        sql, params = App::Internal.rename_paul.then { [it._1, it._2] }
        expect(sql).to eql 'UPDATE patients SET name = ? WHERE id = ?'
        expect(params).to eql ['Saul', 42]
      end

      it 'delete renders DELETE … WHERE pk = ?' do
        sql, params = App::Internal.delete_paul.then { [it._1, it._2] }
        expect(sql).to eql 'DELETE FROM patients WHERE id = ?'
        expect(params).to eql [42]
      end

      it 'insert_all renders multi-row VALUES' do
        sql, params = App::Internal.insert_many.then { [it._1, it._2] }
        expect(sql).to eql 'INSERT INTO patients (name, balance) VALUES (?, ?), (?, ?)'
        expect(params).to eql [
          'Paul',  100,
          'Frank', 200
        ]
      end

      it 'update_all renders bulk UPDATE with predicate' do
        sql, params = App::Internal.update_all_to_zero.then { [it._1, it._2] }
        expect(sql).to eql 'UPDATE patients SET archived = ? WHERE balance = ?'
        expect(params).to eql [true, 0]
      end

      it 'update_many writes every row in one statement' do
        sql, params = App::Internal.update_many_balances.then { [it._1, it._2] }

        expect(sql).to eql(
          'UPDATE patients AS jade_tgt ' \
          'SET name = jade_src.name, balance = jade_src.balance ' \
          'FROM json_populate_recordset(null::patients, ?::json) AS jade_src ' \
          'WHERE jade_tgt.id = jade_src.id',
        )
        expect(params).to eql [
          '[{"id":1,"name":"Ada","balance":10},' \
          '{"id":2,"name":"Grace","balance":20}]',
        ]
      end

      it 'update_all with no assignments reads instead of writing' do
        sql, params = App::Internal.update_all_nothing.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT 1 FROM patients WHERE balance = ?'
        expect(params).to eql [0]
      end

      it 'update_all with no assignments selects what RETURNING would have' do
        sql, params = App::Internal.update_all_nothing_returning.then { [it._1, it._2] }
        expect(sql).to eql 'SELECT id, name, balance FROM patients WHERE balance = ?'
        expect(params).to eql [0]
      end

      it 'delete_all renders bulk DELETE with predicate' do
        sql, params = App::Internal.delete_archived.then { [it._1, it._2] }
        expect(sql).to eql 'DELETE FROM patients WHERE archived = ?'
        expect(params).to eql [true]
      end

      it 'insert + returning projects the table columns into RETURNING' do
        sql, _ = App::Internal.insert_paul_returning.then { [it._1, it._2] }
        expect(sql).to eql 'INSERT INTO patients (name, balance) VALUES (?, ?) RETURNING id, name, balance'
      end

      it 'update + returning appends RETURNING with the projected columns' do
        sql, _ = App::Internal.update_paul_returning.then { [it._1, it._2] }
        expect(sql).to eql 'UPDATE patients SET name = ?, balance = ? WHERE id = ? RETURNING id, name, balance'
      end

      it 'delete + returning appends RETURNING with the projected columns' do
        sql, _ = App::Internal.delete_paul_returning.then { [it._1, it._2] }
        expect(sql).to eql 'DELETE FROM patients WHERE id = ? RETURNING id, name, balance'
      end
    end

    describe 'a composite key' do
      let(:source) do
        <<~JADE
module Comp exposing (touch)

import Sql exposing (
  Assignable,
  Assignment,
  Expr,
  NoJoins,
  Pk,
  Table,
  assign,
  column,
  no_joins,
  pk,
  table,
)
import Encode
import Sql.Mutation exposing (to_sql, update)
import Decode exposing (Value)


struct MembershipsCols = {
  user_id: Expr(Int),
  group_id: Expr(Int),
  role: Expr(String)
}


struct MaybeMembershipsCols = {
  user_id: Expr(Maybe(Int)),
  group_id: Expr(Maybe(Int)),
  role: Expr(Maybe(String))
}


struct Membership = {
  group_id: Int,
  role: String,
  user_id: Int
}


implements Assignable(Membership) with
  to_assigns: encode_membership
end


def encode_membership(m: Membership) -> List(Assignment)
  [
    assign("group_id", m.group_id),
    assign("role", m.role),
    assign("user_id", m.user_id),
  ]
end


def memberships_pk -> Pk(MembershipsCols, (Int, Int))
  pk(["user_id", "group_id"], memberships_pk_values)
end


def memberships_pk_values(v: (Int, Int)) -> List(Value)
  (a, b) = v
  [Encode.encode(a), Encode.encode(b)]
end


def memberships -> Table(MembershipsCols, MaybeMembershipsCols, (Int, Int), NoJoins)
  table(
    "memberships",
    "memberships",
    (a) -> { MembershipsCols(
      column(a, "user_id"),
      column(a, "group_id"),
      column(a, "role"),
    ) },
    (a) -> { MaybeMembershipsCols(
      column(a, "user_id"),
      column(a, "group_id"),
      column(a, "role"),
    ) },
    memberships_pk,
    no_joins,
  )
end


def touch -> (String, List(Value))
  Membership(20, "admin", 10)
    |> update(memberships, (10, 20))
    |> to_sql
end
        JADE
      end

      before { test_compiler.require('comp', source) }

      # The caller supplies a tuple and never a column name; the generated
      # values function spreads it in the order the DDL declares.
      it 'orders the key terms by the schema, not by the caller' do
        sql, params = Comp::Internal.touch.then { [it._1, it._2] }
        expect(sql).to eql 'UPDATE memberships SET role = ? WHERE user_id = ? AND group_id = ?'
        expect(params).to eql ['admin', 10, 20]
      end
    end

    context 'a table with no primary key' do
      let(:source) do
        <<~JADE.strip
module NoPk exposing (touch)

import Sql exposing (
  Assignable,
  Assignment,
  Expr,
  NoJoins,
  NoKey,
  Table,
  assign,
  column,
  no_joins,
  table,
  unkeyed,
)
import Sql.Mutation exposing (Mutation, update)


struct EventsCols = { payload: Expr(String) }


struct MaybeEventsCols = { payload: Expr(Maybe(String)) }


struct Patch = { payload: String }


implements Assignable(Patch) with
  to_assigns: patch_assigns
end


def patch_assigns(p: Patch) -> List(Assignment)
  [assign("payload", p.payload)]
end


def events -> Table(EventsCols, MaybeEventsCols, NoKey, NoJoins)
  table(
    "events",
    "events",
    (a) -> { EventsCols(column(a, "payload")) },
    (a) -> { MaybeEventsCols(column(a, "payload")) },
    unkeyed,
    no_joins,
  )
end


def touch -> Mutation(Int, EventsCols)
  update(Patch("x"), events, 42)
end
        JADE
      end

      it 'refuses a key, since there is no key to name' do
        expect { test_compiler.require('no_pk', source) }
          .to raise_error(/NoKey/)
      end
    end

    describe 'joining through a table\'s on record' do
      let(:source) do
        <<~JADE.strip
module Joined exposing (persons_with_orders)

import Encode
import Sql exposing (
  Expr,
  NoJoins,
  Pk,
  Table,
  column,
  eq,
  no_joins,
  pk,
  table,
)
import Sql.Query exposing (Q, from, join)


struct PersonsCols = { id: Expr(Int) }


struct MaybePersonsCols = { id: Expr(Maybe(Int)) }


struct OrdersCols = { person_id: Expr(Int) }


struct MaybeOrdersCols = { person_id: Expr(Maybe(Int)) }


struct PersonsOn = { orders: PersonsCols -> (OrdersCols -> Expr(Bool)) }


def persons_on_orders(a: PersonsCols) -> (OrdersCols -> Expr(Bool))
  (b) -> { eq(a.id, b.person_id) }
end


def persons -> Table(PersonsCols, MaybePersonsCols, Int, PersonsOn)
  table(
    "persons",
    "p",
    (a) -> { PersonsCols(column(a, "id")) },
    (a) -> { MaybePersonsCols(column(a, "id")) },
    pk(["id"], (v) -> { [Encode.encode(v)] }),
    PersonsOn(persons_on_orders),
  )
end


def orders -> Table(OrdersCols, MaybeOrdersCols, Int, NoJoins)
  table(
    "orders",
    "o",
    (a) -> { OrdersCols(column(a, "person_id")) },
    (a) -> { MaybeOrdersCols(column(a, "person_id")) },
    pk(["person_id"], (v) -> { [Encode.encode(v)] }),
    no_joins,
  )
end


def persons_with_orders -> Q(OrdersCols)
  p <- from(persons)
  join(orders, p |> persons.on.orders)
end
        JADE
      end

      before { test_compiler.require('joined', source) }

      # The parent columns pipe in; `join` supplies the child\'s, which it is
      # the only one holding.
      it 'builds the same predicate a hand-written lambda would' do
        Joined::Internal.persons_with_orders.then do |q|
          expect(q.joins.first.on.sql).to eql 'p.id = o.person_id'
        end
      end
    end

  end
end
