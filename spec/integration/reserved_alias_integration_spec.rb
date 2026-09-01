require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'
require 'jade-sql/bin/generate_schema'

module Jade
  describe 'reserved-word column round-trips via the generated projector', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    def conn = JadeSql::TestDb.connection

    let(:schema_sql) do
      <<~SQL
        CREATE TABLE public.journal_entries (
            id bigint NOT NULL,
            type text NOT NULL,
            memo text
        );

        ALTER TABLE ONLY public.journal_entries
            ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);
      SQL
    end

    let(:app) do
      <<~JADE
        module App exposing (load)

        import Sql exposing (SqlError)
        import Sql.Query exposing (Query, fetch_many, from)
        import Schema exposing (JournalEntriesRow, journal_entries, journal_entries_row)


        def rows -> Query(Sql.Selector(JournalEntriesRow))
          c <- from(journal_entries)
          journal_entries_row(c)
        end


        def load -> Task(List(JournalEntriesRow), SqlError)
          rows |> fetch_many
        end
      JADE
    end

    before do
      conn.execute("DROP TABLE IF EXISTS journal_entries")
      conn.execute(<<~SQL)
        CREATE TABLE journal_entries (
          id   bigint PRIMARY KEY,
          type text   NOT NULL,
          memo text
        )
      SQL
      conn.execute("INSERT INTO journal_entries (id, type, memo) VALUES (1, 'income', 'salary')")

      test_compiler.require('schema', JadeSql::SchemaGenerator.generate(schema_sql))
      test_compiler.require('app', app)
    end

    after { conn.execute("DROP TABLE IF EXISTS journal_entries") }

    it 'decodes the type column into the type_ field' do
      result = App::Internal.load.run

      expect(result).to be_ok
      expect(result._1.length).to eql 1
      expect(result._1.first.type_).to eql 'income'
    end
  end
end
