require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'

describe 'reading a shape the table does not have' do
  include_context 'with test compiler'

  before do
    test_compiler.require('schema', JadeSql::SchemaGenerator.generate(<<~SQL).fetch('Schema'))
      CREATE TABLE public.patients (
          id bigint NOT NULL,
          name character varying NOT NULL,
          nickname character varying
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

  def compile(body)
    test_compiler.require('reader', <<~JADE)
      module Reader exposing (Row(..), one)

      import Schema exposing (PatientsOn(..), VisitsCols, VisitsLeftCols, patients, visits)
      import Sql exposing (SqlError, Table)
      import Sql.Query exposing (Query, Select, fetch_row, fetch_rows, from, join, left_join, selected)


      struct Row = {
        id: Int,
        name: String
      }


      #{body.strip}
    JADE
  end

  def joined(kind, cols, shape)
    <<~JADE
      def joined -> Query(#{cols})
        p <- from(patients)

        visits |> #{kind}(p |> patients.on.visits)
      end


      def one -> Task(#{shape}, SqlError)
        joined |> fetch_row
      end
    JADE
  end

  it 'accepts a shape whose fields are all columns' do
    expect { compile("def one -> Task(Row, SqlError)\n  from(patients) |> fetch_row\nend") }
      .not_to raise_error
  end

  it 'refuses a field the table has no column for' do
    expect { compile("def one -> Task({ nick: String }, SqlError)\n  from(patients) |> fetch_row\nend") }
      .to raise_error(Jade::CompilationError, /has no column/)
  end

  it 'refuses a field whose type disagrees with the column' do
    expect { compile("def one -> Task({ name: Int }, SqlError)\n  from(patients) |> fetch_row\nend") }
      .to raise_error(Jade::CompilationError, /is String, but/)
  end

  it 'refuses a nullable column read into a field that cannot be empty' do
    expect { compile("def one -> Task({ nickname: String }, SqlError)\n  from(patients) |> fetch_row\nend") }
      .to raise_error(Jade::CompilationError, /is Maybe\(String\), but/)
  end

  it 'checks every row of fetch_rows' do
    expect { compile("def one -> Task(List({ name: Int }), SqlError)\n  from(patients) |> fetch_rows\nend") }
      .to raise_error(Jade::CompilationError, /is String, but/)
  end

  it 'checks a query projected by selected' do
    expect { compile("def one -> Select({ name: Int })\n  from(patients) |> selected\nend") }
      .to raise_error(Jade::CompilationError, /is String, but/)
  end

  it 'checks a joined read against the joined table' do
    expect { compile(joined('join', 'VisitsCols', '{ patient_id: Int }')) }
      .not_to raise_error
  end

  it 'refuses a joined read of a column only the first table has' do
    expect { compile(joined('join', 'VisitsCols', '{ nickname: Maybe(String) }')) }
      .to raise_error(Jade::CompilationError, /has no column/)
  end

  it 'makes a left-joined read say its fields may be empty' do
    expect { compile(joined('left_join', 'VisitsLeftCols', '{ name: String }')) }
      .to raise_error(Jade::CompilationError, /is Maybe\(String\), but/)
  end

  it 'accepts a left-joined read whose fields may be empty' do
    expect { compile(joined('left_join', 'VisitsLeftCols', '{ patient_id: Maybe(Int) }')) }
      .not_to raise_error
  end

  it 'says when nothing decides the shape' do
    expect { compile(<<~JADE.strip) }
      def one -> Task(Int, SqlError)
        row <- from(patients) |> fetch_row
        Task.succeed(1)
      end
    JADE
      .to raise_error(Jade::CompilationError, /nothing here says what that type is/)
  end

  it 'says which field has no type yet' do
    expect { compile("def one -> Task({ name: a }, SqlError)\n  from(patients) |> fetch_row\nend") }
      .to raise_error(Jade::CompilationError, /nothing here says what `name` is/)
  end
end
