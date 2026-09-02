require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'
require 'jade-sql/schema_drift'

describe JadeSql::SchemaDrift do
  def schema(sql)
    JadeSql::SchemaGenerator.generate(sql)
  end

  let(:patients) do
    <<~SQL
      CREATE TABLE public.patients (
          id bigint NOT NULL,
          name character varying NOT NULL
      );

      ALTER TABLE ONLY public.patients
          ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
    SQL
  end

  it 'says nothing when the schema was generated from this database' do
    expect(described_class.between(schema(patients), schema(patients))).not_to be_any
  end

  context 'when a column was added to the database' do
    let(:widened) { patients.sub('name character varying NOT NULL', "name character varying NOT NULL,\n    seen_on date") }

    subject { described_class.between(schema(widened), schema(patients)) }

    # One table generates eight definitions, and naming all eight says less
    # than naming the table.
    it 'names the table once, not every definition built from it' do
      expect(subject.changed).to eq ['patients']
    end

    it 'says what to do about it' do
      expect(subject.to_s).to include 'Regenerate it with `jade-sql schema`'
    end
  end

  context 'when a table was added to the database' do
    let(:with_visits) do
      patients + <<~SQL
        CREATE TABLE public.visits (
            id bigint NOT NULL
        );

        ALTER TABLE ONLY public.visits
            ADD CONSTRAINT visits_pkey PRIMARY KEY (id);
      SQL
    end

    subject { described_class.between(schema(with_visits), schema(patients)) }

    it 'is missing here' do
      expect(subject.added).to eq ['visits']
    end
  end

  context 'when a table was dropped from the database' do
    let(:with_visits) do
      patients + <<~SQL
        CREATE TABLE public.visits (
            id bigint NOT NULL
        );

        ALTER TABLE ONLY public.visits
            ADD CONSTRAINT visits_pkey PRIMARY KEY (id);
      SQL
    end

    subject { described_class.between(schema(patients), schema(with_visits)) }

    it 'is gone from the database' do
      expect(subject.removed).to eq ['visits']
    end
  end

  # An enum is a module of its own, so dropping one from the database removes
  # a whole module rather than definitions inside one. Concatenating the
  # modules before comparing would have reported its type as a lost definition
  # with no table to group it under.
  context 'when an enum was dropped from the database' do
    let(:with_enum) do
      <<~SQL
        CREATE TYPE public.visit_status AS ENUM ('scheduled', 'done');

        CREATE TABLE public.patients (
            id bigint NOT NULL,
            status public.visit_status NOT NULL
        );

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
      SQL
    end

    let(:without_enum) do
      with_enum
        .sub(/CREATE TYPE.*?\n\n/m, '')
        .sub('status public.visit_status NOT NULL', 'status text NOT NULL')
    end

    subject { described_class.between(schema(without_enum), schema(with_enum)) }

    it 'names the module, not the type inside it' do
      expect(subject.removed).to eq ['Schema.VisitStatus']
    end

    it 'still reports the column that changed with it' do
      expect(subject.changed).to eq ['patients']
    end
  end
end
