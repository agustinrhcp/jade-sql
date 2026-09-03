require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'

describe 'select_fields' do
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
      import Sql.Query exposing (Query, Select, from, select_fields, to_sql)


      struct Row = {
        id: Int,
        name: String
      }


      def rows -> Select(Row)
        from(patients) |> select_fields
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
      import Sql.Query exposing (Query, Select, from, select_fields, to_sql)


      def rows -> Select({ name: String })
        from(patients) |> select_fields
      end


      def sql -> (String, List(Value))
        to_sql(rows)
      end
    JADE

    expect(Anon.sql.first).to start_with 'SELECT name FROM patients'
  end
end
