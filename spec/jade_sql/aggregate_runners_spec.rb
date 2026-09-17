require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade/tasks'
require 'jade/tasks/rspec'

require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'reads with nothing to decode' do
    include_context 'with test compiler'
    include Jade::Tasks::RSpec

    let(:source) do
      <<~JADE
        module App exposing (has_named, how_many)

        import Sql exposing (
          Col(..),
          Expr,
          NoJoins,
          NoRequiredCols,
          Pk,
          SqlError,
          Table,
          column,
          columns,
          eq,
          no_joins,
          pk,
          table,
        )
        import Sql.Query exposing (Query, fetch_count, fetch_exists, from, where)
        import Encode
        import Decode exposing (Value)


        #{jade_table('patients', { id: 'Int', name: 'String' }, alias_: 'p')}


        def how_many -> Task(Int, SqlError)
          from(patients) |> fetch_count
        end


        def has_named -> Task(Bool, SqlError)
          from(patients)
            |> where(columns(patients).name |> eq("Ada"))
            |> fetch_exists
        end
      JADE
    end

    before { test_compiler.require('app', source) }

    it 'counts over the query clauses rather than a projection' do
      all_calls_to(JadeSql::Runtime.port_execute_one) do |t, sql, _params|
        expect(sql).to include('SELECT COUNT(*) AS tally')
        expect(sql).to include('FROM patients p')

        t.ok({ 'tally' => 7 })
      end

      expect(App.how_many).to eql ['ok', 7]
    end

    it 'asks Postgres to stop at the first row rather than count them' do
      all_calls_to(JadeSql::Runtime.port_execute_one) do |t, sql, _params|
        expect(sql).to include('SELECT EXISTS (SELECT 1 FROM patients p')
        expect(sql).to include('WHERE p.name = ?')

        t.ok({ 'present' => true })
      end

      expect(App.has_named).to eql ['ok', true]
    end
  end
end
