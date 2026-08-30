require 'spec_helper'

require 'jade-sql/bin/generate_schema'

describe JadeSql::SchemaGenerator do
  subject(:generated) { described_class.generate(sql) }

  context 'a single table with NOT NULL and nullable columns' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            name character varying NOT NULL,
            balance integer
        );

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
      SQL
    end

    it 'emits the module header' do
      expect(generated).to include(<<~JADE.strip)
        module Schema exposing (
          MaybePatientsCols,
          PatientsCols,
          PatientsRow(..),
          patients,
          patients_pk,
          patients_row,
        )
      JADE
    end

    it 'emits a row struct: value types, nullable wrapped in Maybe' do
      expect(generated).to include(<<~STRUCT.strip)
        struct PatientsRow = {
          id: Int,
          name: String,
          balance: Maybe(Int)
        }
      STRUCT
    end

    it 'imports Sql' do
      expect(generated).to include('import Sql exposing (Expr, NoJoins(..), Pk(..), Selector, Table, column, table)')
      expect(generated).to include('import Encode')
    end

    it 'does not emit Calendar/Clock imports when the schema does not use them' do
      expect(generated).not_to include('import Calendar')
      expect(generated).not_to include('import Clock')
    end

    it 'emits a strict struct: NOT NULL → Expr(T), nullable → Expr(Maybe(T))' do
      expect(generated).to include(<<~STRUCT.strip)
        struct PatientsCols = {
          id: Expr(Int),
          name: Expr(String),
          balance: Expr(Maybe(Int))
        }
      STRUCT
    end

    it 'emits a maybe struct: every field wrapped in Maybe' do
      expect(generated).to include(<<~STRUCT.strip)
        struct MaybePatientsCols = {
          id: Expr(Maybe(Int)),
          name: Expr(Maybe(String)),
          balance: Expr(Maybe(Int))
        }
      STRUCT
    end

    it 'emits a table function with alias = table name and its key' do
      expect(generated).to include(<<~FN.strip)
        def patients -> Table(PatientsCols, MaybePatientsCols, Int, NoJoins)
          table(
            "patients",
            "patients",
            (a) -> { PatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            (a) -> { MaybePatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            patients_pk,
            NoJoins,
          )
      FN
    end

    it 'emits the key as a value typed to the table it came from' do
      expect(generated).to include(<<~FN.strip)
        def patients_pk -> Pk(PatientsCols, Int)
          Pk(["id"], patients_pk_values)
        end


        def patients_pk_values(v: Int) -> List(Decode.Value)
          [Encode.encode(v)]
        end
      FN
    end
  end

  context 'type mapping' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.kitchen_sink (
            i bigint NOT NULL,
            j smallint NOT NULL,
            s text NOT NULL,
            v character varying NOT NULL,
            b boolean NOT NULL,
            j_blob jsonb NOT NULL,
            d date NOT NULL,
            ts timestamp(6) without time zone NOT NULL,
            u uuid NOT NULL
        );
      SQL
    end

    it 'maps each SQL type to the right Jade type' do
      expect(generated).to include(<<~STRUCT.strip)
        struct KitchenSinkCols = {
          i: Expr(Int),
          j: Expr(Int),
          s: Expr(String),
          v: Expr(String),
          b: Expr(Bool),
          j_blob: Expr(Decode.Value),
          d: Expr(Calendar.Date),
          ts: Expr(Clock.Instant),
          u: Expr(Uuid)
        }
      STRUCT
    end

    it 'emits the Calendar/Clock/Decode/Sql.Uuid imports when those types appear' do
      expect(generated).to include('import Calendar')
      expect(generated).to include('import Clock')
      expect(generated).to include('import Decode')
      expect(generated).to include('import Sql.Uuid exposing (Uuid)')
    end
  end

  context 'array columns' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.transaction_lines (
            id bigint NOT NULL,
            tags text[] NOT NULL,
            scores integer[] NOT NULL,
            owners uuid[] NOT NULL,
            extras jsonb[]
        );
      SQL
    end

    it 'maps array SQL types to List(...) Jade types' do
      expect(generated).to include(<<~STRUCT.strip)
        struct TransactionLinesCols = {
          id: Expr(Int),
          tags: Expr(List(String)),
          scores: Expr(List(Int)),
          owners: Expr(List(Uuid)),
          extras: Expr(Maybe(List(Decode.Value)))
        }
      STRUCT
    end

    it 'pulls in the Sql.Uuid / Decode imports for array element types' do
      expect(generated).to include('import Sql.Uuid exposing (Uuid)')
      expect(generated).to include('import Decode')
    end
  end

  context 'foreign keys' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id uuid NOT NULL,
            phone_id uuid,
            name text NOT NULL
        );

        CREATE TABLE public.phones (
            id uuid NOT NULL,
            number text NOT NULL
        );

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT patients_pkey PRIMARY KEY (id);

        ALTER TABLE ONLY public.phones
            ADD CONSTRAINT phones_pkey PRIMARY KEY (id);

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT fk_phone FOREIGN KEY (phone_id) REFERENCES public.phones(id);
      SQL
    end

    it 'names the outgoing side after the column, minus its _id' do
      expect(generated).to include(<<~JADE.strip)
        struct PatientsOn = { phone: PatientsCols -> (PhonesCols -> Expr(Bool)) }
      JADE
    end

    it 'names the incoming side after the table it comes from' do
      expect(generated).to include(<<~JADE.strip)
        struct PhonesOn = { patients: PhonesCols -> (PatientsCols -> Expr(Bool)) }
      JADE
    end

    it 'lifts the non-nullable side, since a nullable key is Expr(Maybe(a))' do
      expect(generated).to include(<<~JADE.strip)
        def patients_on_phone(a: PatientsCols) -> (PhonesCols -> Expr(Bool))
          (b) -> { eq(a.phone_id, b.id |> nullable) }
        end
      JADE

      expect(generated).to include(<<~JADE.strip)
        def phones_on_patients(a: PhonesCols) -> (PatientsCols -> Expr(Bool))
          (b) -> { eq(a.id |> nullable, b.phone_id) }
        end
      JADE
    end

    it 'hands the record to the table' do
      expect(generated).to include('def patients -> Table(PatientsCols, MaybePatientsCols, Uuid, PatientsOn)')
      expect(generated).to include('PatientsOn(patients_on_phone),')
    end
  end

  context 'multi-column primary key' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.memberships (
            user_id bigint NOT NULL,
            group_id bigint NOT NULL
        );

        ALTER TABLE ONLY public.memberships
            ADD CONSTRAINT memberships_pkey PRIMARY KEY (user_id, group_id);
      SQL
    end

    it 'spreads a composite key across its columns, in DDL order' do
      expect(generated).to include(<<~FN.strip)
        def memberships_pk -> Pk(MembershipsCols, (Int, Int))
          Pk(["user_id", "group_id"], memberships_pk_values)
        end


        def memberships_pk_values(v: (Int, Int)) -> List(Decode.Value)
          (v0, v1) = v

          [Encode.encode(v0), Encode.encode(v1)]
        end
      FN
    end
  end

  context 'table without an explicit primary key constraint' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.events (
            payload jsonb NOT NULL
        );
      SQL
    end

    it 'keys the table by NoKey and passes unkeyed' do
      expect(generated).to include('def events -> Table(EventsCols, MaybeEventsCols, NoKey, NoJoins)')
      expect(generated).to include('unkeyed,')
    end

    it 'emits no key value, since there is no key to name' do
      expect(generated).not_to include('events_pk')
    end
  end

  context 'AR-emitted schema_migrations table' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.schema_migrations (
            version character varying NOT NULL
        );

        ALTER TABLE ONLY public.schema_migrations
            ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);
      SQL
    end

    it 'is generated like any other table' do
      expect(generated).to include('def schema_migrations -> Table(SchemaMigrationsCols, MaybeSchemaMigrationsCols, String, NoJoins)')
      expect(generated).to include('["version"]')
    end
  end

  context 'multiple tables in one SQL file' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.persons (
            id bigint NOT NULL,
            name character varying NOT NULL
        );

        ALTER TABLE ONLY public.persons
            ADD CONSTRAINT persons_pkey PRIMARY KEY (id);

        CREATE TABLE public.orders (
            id bigint NOT NULL,
            person_id bigint NOT NULL
        );

        ALTER TABLE ONLY public.orders
            ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
      SQL
    end

    it 'emits both table functions' do
      expect(generated).to include('def persons -> Table')
      expect(generated).to include('def orders -> Table')
    end

    it 'exposes both, sorted' do
      m = generated.match(/module Schema exposing \(\s*(.+?)\s*\)\s*\nimport/m)
      expect(m).not_to be_nil
      entries = m[1].split(',').map { |e| e.strip.sub(/,\z/, '') }.reject(&:empty?)
      expect(entries).to eql %w[
        MaybeOrdersCols MaybePersonsCols OrdersCols OrdersRow(..)
        PersonsCols PersonsRow(..) orders orders_pk orders_row
        persons persons_pk persons_row
      ]
    end

    context 'with a table whitelist' do
      subject(:generated) { described_class.generate(sql, tables: ['persons']) }

      it 'only emits the listed tables' do
        expect(generated).to include('def persons -> Table')
        expect(generated).not_to include('def orders -> Table')
      end

      it 'fails loudly when a listed table is not in the SQL' do
        expect { described_class.generate(sql, tables: ['persons', 'typo']) }
          .to raise_error(/Unknown table.*typo/)
      end
    end

    context 'with a custom module name' do
      subject(:generated) { described_class.generate(sql, module_name: 'Schema.Billing') }

      it 'uses the override in the module declaration' do
        expect(generated).to include('module Schema.Billing exposing (')
      end
    end
  end

  context 'unknown SQL type' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.payments (
            amount money NOT NULL
        );
      SQL
    end

    it 'fails loudly with table and column name' do
      expect { generated }.to raise_error(/payments\.amount.*money/)
    end
  end

  context 'ignores AR boilerplate' do
    let(:sql) do
      <<~SQL
        SET statement_timeout = 0;
        SET lock_timeout = 0;

        CREATE TABLE public.persons (
            id bigint NOT NULL
        );

        CREATE SEQUENCE public.persons_id_seq AS integer;
        ALTER SEQUENCE public.persons_id_seq OWNED BY public.persons.id;
        ALTER TABLE ONLY public.persons ALTER COLUMN id SET DEFAULT nextval('public.persons_id_seq'::regclass);

        ALTER TABLE ONLY public.persons
            ADD CONSTRAINT persons_pkey PRIMARY KEY (id);

        CREATE INDEX index_persons_on_name ON public.persons USING btree (id);
      SQL
    end

    it 'still parses the persons table cleanly' do
      expect(generated).to include('def persons -> Table')
      expect(generated).to include('["id"]')
    end
  end

  context 'numeric / decimal / floating-point columns' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.tax_lines (
            id bigint NOT NULL,
            rate numeric(5,4) NOT NULL,
            amount decimal NOT NULL,
            weight double precision,
            ratio real
        );
      SQL
    end

    it 'maps numeric/decimal to Decimal and double precision/real to Float' do
      generated = described_class.generate(sql)

      expect(generated).to include(<<~STRUCT.strip)
        struct TaxLinesRow = {
          id: Int,
          rate: Decimal,
          amount: Decimal,
          weight: Maybe(Float),
          ratio: Maybe(Float)
        }
      STRUCT
      expect(generated).to include('import Decimal exposing (Decimal)')
    end
  end

  context 'a column whose name is a Jade reserved word' do
    include_context 'with test compiler'

    let(:sql) do
      <<~SQL
        CREATE TABLE public.journal_entries (
            id bigint NOT NULL,
            type text NOT NULL
        );
      SQL
    end

    it 'renames the field to type_ but keeps the SQL column name' do
      expect(generated).to include('type_: Expr(')
      expect(generated).to include('column(a, "type")')
    end

    it 'emits a row projector that aliases each column to its field name' do
      expect(generated).to include('def journal_entries_row(c: JournalEntriesCols)')
      expect(generated).to include('field_as(c.type_, "type_")')
      expect(generated).to include('import Sql.Query exposing (Q, field_as, select)')
    end

    it 'produces a schema that compiles' do
      expect { test_compiler.require('schema', generated) }.not_to raise_error
    end
  end

  context 'an unsupported type in a table outside the whitelist' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.wanted (
            id bigint NOT NULL,
            name text NOT NULL
        );

        CREATE TABLE public.unwanted (
            id bigint NOT NULL,
            blob bytea NOT NULL
        );
      SQL
    end

    it 'does not abort when the unsupported type is filtered out' do
      result = described_class.generate(sql, tables: ['wanted'])
      expect(result).to include('def wanted -> Table')
      expect(result).not_to include('unwanted')
    end

    it 'still raises when the unsupported type is in a whitelisted table' do
      expect { described_class.generate(sql, tables: ['unwanted']) }
        .to raise_error(/Unknown SQL type for unwanted.blob/)
    end
  end

  describe 'column selection' do
    subject(:generated) { described_class.generate(sql, columns: columns) }

    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            name character varying NOT NULL,
            ssn character varying NOT NULL,
            age integer
        );

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
      SQL
    end

    context 'a domain granted a subset' do
      let(:columns) { { 'patients' => %w[id age] } }

      it 'keeps the granted columns' do
        expect(generated).to include('age: Expr(Maybe(Int))')
      end

      it 'omits the columns it was not granted' do
        expect(generated).to_not include('ssn')
      end

      it 'omits them from the row struct too' do
        expect(generated).to_not match(/struct PatientsRow.*ssn/m)
      end
    end

    context 'a table left out of the map' do
      let(:columns) { { 'other' => %w[id] } }

      it 'keeps every column' do
        expect(generated).to include('ssn')
      end
    end

    context 'a column that does not exist' do
      let(:columns) { { 'patients' => %w[id nope] } }

      it 'says so rather than silently dropping it' do
        expect { generated }.to raise_error(/Unknown column\(s\) on patients: nope/)
      end
    end

    context 'a selection that drops the primary key' do
      let(:columns) { { 'patients' => %w[age] } }

      it 'refuses, since the emitted table would name a column it lacks' do
        expect { generated }.to raise_error(/primary key id must be selected/)
      end
    end
  end

end
