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

      CREATE TABLE public.visits (
          id bigint NOT NULL,
          patient_id bigint NOT NULL,
          name character varying NOT NULL
      );

      ALTER TABLE ONLY public.patients
          ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.visits
          ADD CONSTRAINT visits_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.visits
          ADD CONSTRAINT visits_patient_fk FOREIGN KEY (patient_id) REFERENCES public.patients(id);
    SQL
  end

  # The generator returns a module per enum plus the root one; this schema
  # declares none, so the root is all of it.
  before do
    test_compiler.require('schema', JadeSql::SchemaGenerator.generate(schema_sql).fetch('Schema'))
  end

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

    expect(Reads.sql.first).to start_with 'SELECT patients.id, patients.name FROM patients'
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

    expect(Anon.sql.first).to start_with 'SELECT patients.name FROM patients'
  end
  # The reader is where the shape and the query meet, so this is the call
  # that has to type check: nothing in it names a column.
  it 'reads a row without a select' do
    test_compiler.require('reader', <<~JADE)
      module Reader exposing (Row(..), many, one)

      import Schema exposing (patients)
      import Sql exposing (SqlError)
      import Sql.Query exposing (fetch_many, fetch_one, from, selected)


      struct Row = {
        id: Int,
        name: String
      }


      def one -> Task(Row, SqlError)
        from(patients)
          |> selected
          |> fetch_one
      end


      def many -> Task(List(Row), SqlError)
        from(patients)
          |> selected
          |> fetch_many
      end
    JADE

    expect(defined?(Reader)).to eq 'constant'
  end


  it 'qualifies the columns with the table whose columns the query carries' do
    test_compiler.require('joined', <<~JADE)
      module Joined exposing (rows, sql)

      import Schema exposing (PatientsOn(..), VisitsCols, patients, visits)
      import Decode exposing (Value)
      import Sql exposing (Selector, Table)
      import Sql.Query exposing (Query, Select, from, join, selected, to_sql)


      def joined -> Query(VisitsCols)
        p <- from(patients)

        visits |> join(p |> patients.on.visits)
      end


      def rows -> Select({ name: String })
        joined |> selected
      end


      def sql -> (String, List(Value))
        to_sql(rows)
      end
    JADE

    expect(Joined.sql.first).to start_with 'SELECT visits.name FROM patients'
  end
  # A write asks its rows back the same way, and RETURNING resolves against
  # the one table being written, so the names go in bare.
  it 'returns the fields of the result type from a write' do
    test_compiler.require('writes', <<~JADE)
      module Writes exposing (Row(..), sql)

      import Schema exposing (PatientsCols, PatientsSetCols, patients)
      import Decode exposing (Value)
      import Sql exposing (Selector, assign)
      import Sql.Write exposing (Write, insert, returning, to_sql)


      struct Row = {
        id: Int,
        name: String
      }


      def created -> Write(Row, PatientsCols, PatientsSetCols)
        [assign("name", "Ada")]
          |> insert(patients)
          |> returning
      end


      def sql -> (String, List(Value))
        to_sql(created)
      end
    JADE

    expect(Writes.sql.first)
      .to eq 'INSERT INTO patients (name) VALUES (?) RETURNING id, name'
  end
end
