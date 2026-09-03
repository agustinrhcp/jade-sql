require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'

describe 'reading without a select' do
  include_context 'with test compiler'

  let(:schema_sql) do
    <<~SQL
      CREATE TABLE public.patients (
          id bigint NOT NULL,
          name character varying NOT NULL,
          seen_on date
      );

      ALTER TABLE ONLY public.patients
          ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
    SQL
  end

  before { test_compiler.require('schema', JadeSql::SchemaGenerator.generate(schema_sql)) }

  it 'selects the fields of the result type, in order' do
    test_compiler.require('reads', <<~JADE)
      module Reads exposing (Row(..), rows, sql)

      import Schema exposing (patients)
      import Decode exposing (Value)
      import Sql exposing (Selector)
      import Sql.Query exposing (Query, Select, from, selected, to_sql)


      struct Row = {
        id: Int,
        name: String
      }


      def rows -> Select(Row)
        from(patients) |> selected
      end


      def sql -> (String, List(Value))
        to_sql(rows)
      end
    JADE

    expect(Reads.sql.first).to start_with 'SELECT id, name FROM patients'
  end

  # The shape asked for does not have to be declared: a record written where
  # the result goes names the columns just as well.
  it 'takes an anonymous record as the shape' do
    test_compiler.require('anon', <<~JADE)
      module Anon exposing (rows, sql)

      import Schema exposing (patients)
      import Decode exposing (Value)
      import Sql exposing (Selector)
      import Sql.Query exposing (Query, Select, from, selected, to_sql)


      def rows -> Select({ name: String })
        from(patients) |> selected
      end


      def sql -> (String, List(Value))
        to_sql(rows)
      end
    JADE

    expect(Anon.sql.first).to start_with 'SELECT name FROM patients'
  end
  # The reader is where the shape and the query meet, so this is the call
  # that has to type check: nothing in it names a column.
  it 'reads a row without a select' do
    test_compiler.require('reader', <<~JADE)
      module Reader exposing (Row(..), many, one)

      import Schema exposing (patients)
      import Sql exposing (SqlError)
      import Sql.Query exposing (fetch_row, fetch_rows, from)


      struct Row = {
        id: Int,
        name: String
      }


      def one -> Task(Row, SqlError)
        from(patients) |> fetch_row
      end


      def many -> Task(List(Row), SqlError)
        from(patients) |> fetch_rows
      end
    JADE

    expect(defined?(Reader)).to eq 'constant'
  end

end
