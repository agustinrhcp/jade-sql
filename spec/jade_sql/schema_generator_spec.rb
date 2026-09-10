require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'

describe JadeSql::SchemaGenerator do
  subject(:generated) { modules.fetch(root_module) }

  let(:modules) { described_class.generate(sql) }
  let(:root_module) { 'Schema' }

  # The write specs build their tables with `jade_table` rather than from
  # DDL, so a column shape the helper and the generator disagree on is a shape
  # nothing exercises. `RequiredPatientsCols` is deliberately not compared:
  # the helper excludes the key by convention, the generator by reading the
  # DDL for what fills it.
  context 'agreeing with the spec fixture helper' do
    include JadeTables

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

    let(:fixture) do
      jade_table('patients', { id: 'Int', name: 'String', balance: 'Maybe(Int)' })
    end

    def struct_block(text, name)
      text[/^struct #{name} = \{.*?\n\}$/m] || text[/^struct #{name} = \{[^\n]*\}$/]
    end

    %w[PatientsCols PatientsLeftCols PatientsSetCols].each do |name|
      it "emits #{name} the way the helper does" do
        expect(struct_block(generated, name)).to eql struct_block(fixture, name)
      end
    end
  end

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
          Patients,
          PatientsCols,
          PatientsLeftCols,
          PatientsRow(..),
          PatientsSetCols,
          RequiredPatientsCols,
          patients,
          patients_pkey,
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
      expect(generated).to include('import Sql exposing (
  Col(..),
  Expr,
  NoJoins,
  Pk,
  Selector,
  Table,
  Unique,
  column,
  no_joins,
  pk,
  table,
  unique,
)')
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
        struct PatientsLeftCols = {
          id: Expr(Maybe(Int)),
          name: Expr(Maybe(String)),
          balance: Expr(Maybe(Int))
        }
      STRUCT
    end

    it 'emits a set struct: NOT NULL -> Col(T), nullable -> Col(Maybe(T))' do
      expect(generated).to include(<<~STRUCT.strip)
        struct PatientsSetCols = {
          id: Col(Int),
          name: Col(String),
          balance: Col(Maybe(Int))
        }
      STRUCT
    end

    it 'emits a table function with alias = table name and its key' do
      expect(generated).to include(<<~FN.strip)
        def patients -> Patients
          table(
            "patients",
            "patients",
            (a) -> {
              PatientsCols(column(a, "id"), column(a, "name"), column(a, "balance"))
            },
            (a) -> {
              PatientsLeftCols(column(a, "id"), column(a, "name"), column(a, "balance"))
            },
            patients_set_cols,
            patients_pk,
            no_joins,
          )
      FN
    end

    it 'emits the key as a value typed to the table it came from' do
      expect(generated).to include(<<~FN.strip)
        def patients_pk -> Pk(PatientsCols, Int)
          pk("patients_pkey", ["id"], patients_pk_values)
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
          (b) -> { Expr.eq(a.phone_id, b.id |> nullable) }
        end
      JADE

      expect(generated).to include(<<~JADE.strip)
        def phones_on_patients(a: PhonesCols) -> (PatientsCols -> Expr(Bool))
          (b) -> { Expr.eq(a.id |> nullable, b.phone_id) }
        end
      JADE
    end

    it 'hands the record to the table' do
      expect(generated).to include('def patients -> Patients')
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
          pk("memberships_pkey", ["user_id", "group_id"], memberships_pk_values)
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
      expect(generated).to include('def events -> Events')
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
      expect(generated).to include('def schema_migrations -> SchemaMigrations')
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
      expect(generated).to include('def persons -> Persons')
      expect(generated).to include('def orders -> Orders')
    end

    it 'exposes both, sorted' do
      m = generated.match(/module Schema exposing \(\s*(.+?)\s*\)\s*\nimport/m)
      expect(m).not_to be_nil
      entries = m[1].split(',').map { |e| e.strip.sub(/,\z/, '') }.reject(&:empty?)
      expect(entries).to eql %w[
        Orders OrdersCols OrdersLeftCols OrdersRow(..) OrdersSetCols Persons
        PersonsCols PersonsLeftCols PersonsRow(..) PersonsSetCols
        RequiredOrdersCols RequiredPersonsCols
        orders orders_pkey orders_row
        persons persons_pkey persons_row
      ]
    end

    context 'with a table whitelist' do
      let(:modules) { described_class.generate(sql, tables: ['persons']) }

      it 'only emits the listed tables' do
        expect(generated).to include('def persons -> Persons')
        expect(generated).not_to include('def orders -> Table')
      end

      it 'fails loudly when a listed table is not in the SQL' do
        expect { described_class.generate(sql, tables: ['persons', 'typo']) }
          .to raise_error(/Unknown table.*typo/)
      end
    end

    context 'with a custom module name' do
      let(:modules) { described_class.generate(sql, module_name: 'Schema.Billing') }
      let(:root_module) { 'Schema.Billing' }

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
      expect(generated).to include('def persons -> Persons')
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
      expect(generated).to include(
        'def journal_entries_row(c: JournalEntriesCols) -> Select(JournalEntriesRow)',
      )
      expect(generated).to include('field_as(c.type_, "type_")')
      expect(generated).to include('import Sql.Query exposing (Select, field_as, select)')
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
      result = described_class.generate(sql, tables: ['wanted']).fetch('Schema')
      expect(result).to include('def wanted -> Wanted')
      expect(result).not_to include('unwanted')
    end

    it 'still raises when the unsupported type is in a whitelisted table' do
      expect { described_class.generate(sql, tables: ['unwanted']) }
        .to raise_error(/Unknown SQL type for unwanted.blob/)
    end
  end

  describe 'column selection' do
    let(:modules) { described_class.generate(sql, columns: columns) }

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

  context 'column modifiers in either order' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            name character varying NOT NULL DEFAULT 'anonymous',
            role character varying DEFAULT 'member' NOT NULL,
            note text COLLATE "C"
        );
      SQL
    end

    it 'reads NOT NULL whether it precedes or follows DEFAULT' do
      expect(generated).to include(<<~STRUCT.strip)
        struct PatientsRow = {
          id: Int,
          name: String,
          role: String,
          note: Maybe(String)
        }
      STRUCT
    end
  end

  context 'serial columns' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id serial NOT NULL,
            counter bigserial NOT NULL
        );
      SQL
    end

    it 'maps to Int rather than refusing the type' do
      expect(generated).to include('id: Int')
      expect(generated).to include('counter: Int')
    end
  end

  describe 'which columns the database fills in' do
    subject(:defaulted) do
      described_class
        .send(:scan_table_bodies, sql)
        .flat_map { |name, body| described_class.send(:parse_columns, body, name) }
        .then { described_class.send(:apply_defaults, it, altered) }
        .select(&:defaulted)
        .map(&:name)
    end

    let(:altered) { described_class.send(:parse_alter_defaults, sql)['patients'] || [] }

    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            code bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY,
            state character varying DEFAULT 'new' NOT NULL,
            name character varying NOT NULL
        );

        ALTER TABLE ONLY public.patients
            ALTER COLUMN id SET DEFAULT nextval('public.patients_id_seq'::regclass);
      SQL
    end

    it 'covers inline defaults, identity, and the sequence set afterwards' do
      expect(defaulted).to eql(%w[id code state])
    end
  end

  context 'the columns an insert has to write' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            name character varying NOT NULL,
            state character varying DEFAULT 'new' NOT NULL,
            balance integer,
            created_at timestamp without time zone NOT NULL,
            updated_at timestamp without time zone NOT NULL
        );

        ALTER TABLE ONLY public.patients
            ALTER COLUMN id SET DEFAULT nextval('public.patients_id_seq'::regclass);
      SQL
    end

    it 'skips what the database fills in, and nothing else' do
      expect(generated).to include(<<~STRUCT.strip)
        struct RequiredPatientsCols = {
          name: Expr(String),
          created_at: Expr(Clock.Instant),
          updated_at: Expr(Clock.Instant)
        }
      STRUCT
    end
  end

  context 'a table an insert can leave entirely to the database' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.events (
            id bigint NOT NULL,
            note text
        );

        ALTER TABLE ONLY public.events
            ALTER COLUMN id SET DEFAULT nextval('public.events_id_seq'::regclass);
      SQL
    end

    it 'has no struct to name, so the table is typed NoRequiredCols' do
      expect(generated).not_to include('RequiredEventsCols')
      expect(generated).to include('NoJoins, NoRequiredCols, EventsSetCols)')
    end
  end

  context 'a Postgres enum' do
    # Each enum is a module of its own, so what comes back is keyed by module
    # name rather than being one string.
    def schema_for(*labels)
      described_class.generate(<<~SQL).fetch('Schema.VisitStatus')
        CREATE TYPE public.visit_status AS ENUM (#{labels.map { "'#{it}'" }.join(', ')});

        CREATE TABLE public.visits (
            id bigint NOT NULL,
            status public.visit_status NOT NULL
        );
      SQL
    end

    it 'names one constructor per label' do
      expect(schema_for('scheduled', 'done')).to include(<<~TYPE.strip)
        type VisitStatus
          = Scheduled
          | Done
      TYPE
    end

    # A label is any text Postgres accepts, and Rails apps write them with
    # spaces. Splitting on underscores alone left the space in the
    # constructor, so the generated module did not parse.
    it 'names a constructor for a label carrying punctuation' do
      expect(schema_for('not started', 'in-progress')).to include(<<~TYPE.strip)
        type VisitStatus
          = NotStarted
          | InProgress
      TYPE
    end

    it 'refuses a label no constructor can be named after' do
      expect { schema_for('2fa') }
        .to raise_error(/cannot be a Jade constructor: "2fa"/)
    end

    it 'refuses two labels that name one constructor' do
      expect { schema_for('not started', 'not_started') }
        .to raise_error(/labels that name one constructor: NotStarted/)
    end
  end

  # Emitting something Jade cannot parse has to fail here, where the DDL that
  # caused it can still be named — a build later, against the generated file,
  # nothing points back at it. A composite foreign key emits a broken `on`
  # record, which is what this reaches that path with.
  context 'output Jade cannot parse' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.parents (
            a integer NOT NULL,
            b integer NOT NULL
        );

        CREATE TABLE public.kids (
            a integer NOT NULL,
            b integer NOT NULL
        );

        ALTER TABLE ONLY public.parents
            ADD CONSTRAINT parents_pkey PRIMARY KEY (a, b);
        ALTER TABLE ONLY public.kids
            ADD CONSTRAINT kids_fk FOREIGN KEY (a, b) REFERENCES public.parents(a, b);
      SQL
    end

    it 'raises rather than writing it' do
      expect { generated }
        .to raise_error(
          JadeSql::SchemaGenerator::UnparseableSchema,
          /not valid Jade.*Unexpected token/m,
        )
    end
  end

  # A generated schema has to compile, and only compiling it says so. The `on`
  # record is where that bites: it is the one place the generator writes a
  # curried type and a column-to-column comparison, and both have a spelling
  # the rest of the file never exercises.
  context 'a schema whose tables reference each other' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.imports (
            id integer NOT NULL,
            note text
        );

        CREATE TABLE public.transactions (
            id integer NOT NULL,
            import_id integer NOT NULL
        );

        ALTER TABLE ONLY public.imports
            ADD CONSTRAINT imports_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.transactions
            ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.transactions
            ADD CONSTRAINT transactions_import_fk FOREIGN KEY (import_id) REFERENCES public.imports(id);
      SQL
    end

    include_context 'with test compiler'

    it 'compiles' do
      test_compiler.write('schema', generated)

      expect { test_compiler.compiler.require('schema') }.not_to raise_error
    end

    # A join predicate compares two columns, and `Sql.eq` takes a value.
    it 'compares the two columns with the expression-taking operator' do
      expect(generated).to include('Expr.eq(a.import_id, b.id)')
      expect(generated).to include('import Sql.Expr as Expr')
    end

    # `import_id` names its relation `import`, which no Jade field can be
    # called. It takes the same trailing underscore a reserved column gets.
    it 'renames a relation whose name is a keyword' do
      expect(generated).to include('import_: TransactionsCols')
      expect(generated).to include('def transactions_on_import_(')
    end
  end

  # The spellings pg_dump writes, which are not the ones a migration is
  # written in.
  context 'the shapes pg_dump writes' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.things (
            id bigint NOT NULL,
            legacy_id bigint NOT NULL,
            note character varying(80) NOT NULL,
            tags character varying(255)[],
            amount numeric(6,4) NOT NULL,
            seen timestamp(6) without time zone,
            email public.citext,
            signup_ip inet,
            full_name text GENERATED ALWAYS AS ((note || ' !'::text)) STORED NOT NULL
        );

        ALTER TABLE public.things ALTER COLUMN id
            ADD GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME public.things_id_seq START WITH 1);
        ALTER TABLE public.things ALTER COLUMN legacy_id
            ADD GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME public.things_legacy_id_seq START WITH 1);
        ALTER TABLE ONLY public.things
            ADD CONSTRAINT things_pkey PRIMARY KEY (id);
      SQL
    end

    def required_struct = generated[/struct RequiredThingsCols = \{.*?\n\}/m]

    # A sequence fills these, so an insert supplying one supplies a key it
    # does not own.
    it 'asks an insert for neither identity column' do
      expect(required_struct).not_to include('id')
      expect(required_struct).not_to include('legacy_id')
      expect(generated).to include(<<~STRUCT.strip)
        struct RequiredThingsCols = {
          note: Expr(String),
          amount: Expr(Decimal)
        }
      STRUCT
    end

    it 'asks an insert for no generated column' do
      expect(required_struct).not_to include('full_name')
    end

    it 'reads an array that carries a length' do
      expect(generated).to include('tags: Expr(Maybe(List(String)))')
    end

    it 'reads a length or precision on a scalar' do
      expect(generated).to include('note: Expr(String)')
      expect(generated).to include('amount: Expr(Decimal)')
      expect(generated).to include('seen: Expr(Maybe(Clock.Instant))')
    end

    it 'reads the text-shaped extension and network types' do
      expect(generated).to include('email: Expr(Maybe(String))')
      expect(generated).to include('signup_ip: Expr(Maybe(String))')
    end
  end

  # Guessing buys a column that fails at decode instead of a message naming
  # the DDL.
  context 'a type with no Jade equivalent' do
    %w[interval tsvector bytea money daterange xml].each do |type|
      it "refuses #{type}" do
        expect {
          described_class.generate(<<~SQL)
            CREATE TABLE public.t (
                id integer NOT NULL,
                c #{type}
            );
          SQL
        }.to raise_error(/Unknown SQL type for t.c: "#{type}"/)
      end
    end
  end
  context 'unique indexes' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.users (
            id bigint NOT NULL,
            email character varying NOT NULL,
            tenant_id bigint NOT NULL,
            handle character varying
        );

        ALTER TABLE ONLY public.users
            ADD CONSTRAINT users_pkey PRIMARY KEY (id);

        ALTER TABLE ONLY public.users
            ADD CONSTRAINT users_email_key UNIQUE (email);

        CREATE UNIQUE INDEX index_users_on_tenant_and_handle ON public.users USING btree (tenant_id, handle);

        CREATE UNIQUE INDEX index_users_on_handle_active ON public.users USING btree (handle) WHERE (handle IS NOT NULL);
      SQL
    end

    it 'names a table-level UNIQUE constraint' do
      expect(generated).to include(<<~JADE.strip)
        def users_email_key -> Unique(UsersCols, String)
          unique("users_email_key", ["email"], users_email_key_values)
        end
      JADE
    end

    it 'names a standalone unique index, with its columns in order' do
      expect(generated).to include(<<~JADE.strip)
        def index_users_on_tenant_and_handle -> Unique(UsersCols, (Int, Maybe(String)))
          unique(
            "index_users_on_tenant_and_handle",
            ["tenant_id", "handle"],
            index_users_on_tenant_and_handle_values,
          )
        end
      JADE
    end

    # A partial index constrains only the rows its WHERE matches, so a
    # conflict target built from it is not the one the database enforces.
    it 'skips a partial index' do
      expect(generated).not_to include('index_users_on_handle_active')
    end

    it 'types a composite key as a tuple, nullable columns included' do
      expect(generated).to include(<<~JADE.strip)
        def index_users_on_tenant_and_handle_values(
          v: (Int, Maybe(String)),
        ) -> List(Decode.Value)
      JADE
    end

    it 'exposes them and imports what they need' do
      expect(generated).to include('users_email_key,')
      expect(generated).to include('  Unique,')
      expect(generated).to include('  unique,')
    end
  end


  # Postgres infers a conflict target by the column underneath an operator
  # class, a sort order, a NULLS placement or a collation — all four were
  # verified against a live server as `ON CONFLICT (col)` arbiters. An
  # expression is the one thing it cannot reduce to a column, and `Unique`
  # promises columns a read can bind values to.
  context 'an index whose columns carry more than their names' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.users (
            id bigint NOT NULL,
            email text NOT NULL,
            code text NOT NULL,
            tenant_id integer NOT NULL,
            created_at timestamp without time zone,
            deleted_at timestamp without time zone
        );

        ALTER TABLE ONLY public.users
            ADD CONSTRAINT users_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.users
            ADD CONSTRAINT users_tenant_key UNIQUE NULLS NOT DISTINCT (tenant_id, email);

        CREATE UNIQUE INDEX idx_lower ON public.users USING btree (lower((email)::text));
        CREATE UNIQUE INDEX idx_ops ON public.users USING btree (code text_pattern_ops);
        CREATE UNIQUE INDEX idx_desc ON public.users USING btree (tenant_id, created_at DESC NULLS LAST);
        CREATE UNIQUE INDEX idx_coll ON public.users USING btree (code COLLATE "C");
        CREATE UNIQUE INDEX idx_partial ON public.users USING btree (email) WHERE (deleted_at IS NULL);
      SQL
    end

    it 'reads the column under an operator class' do
      expect(generated).to include(%q{unique("idx_ops", ["code"], idx_ops_values)})
    end

    it 'reads the columns under a sort order and a NULLS placement' do
      expect(generated).to include(%q{unique("idx_desc", ["tenant_id", "created_at"], idx_desc_values)})
    end

    it 'reads the column under a collation' do
      expect(generated).to include(%q{unique("idx_coll", ["code"], idx_coll_values)})
    end

    # `NULLS NOT DISTINCT` sits before the paren on a constraint and after it
    # on an index, so the two spellings of one fact used to disagree.
    it 'reads a constraint declaring NULLS NOT DISTINCT' do
      expect(generated).to include(
        %q{unique("users_tenant_key", ["tenant_id", "email"], users_tenant_key_values)},
      )
    end

    # The column list has to run to the paren that closes it: stopping at the
    # first `)` yields `["lower((email"`, which renders
    # `ON CONFLICT (lower((email) DO NOTHING`.
    it 'skips an expression index rather than emitting half of it' do
      expect(generated).not_to include('idx_lower')
      expect(generated).not_to include('lower(')
    end

    it 'skips a partial index, which constrains only the rows it matches' do
      expect(generated).not_to include('idx_partial')
    end
  end

  # Every other spec here defines its `On` record in the same module as the
  # call site, so none of them exercises what an app actually does: import a
  # generated schema and join through it. Reaching `t.on.rel` needs `Sql.Table`
  # for the first field and the table's own `On` type for the second, which is
  # why both stay exposed.
  context 'joining through a generated on record from another module' do
    let(:sql) do
      <<~SQL
        CREATE TABLE public.patients (
            id bigint NOT NULL,
            name text NOT NULL
        );

        CREATE TABLE public.visits (
            id bigint NOT NULL,
            patient_id bigint NOT NULL
        );

        ALTER TABLE ONLY public.patients
            ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.visits
            ADD CONSTRAINT visits_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.visits
            ADD CONSTRAINT visits_patient_fk FOREIGN KEY (patient_id) REFERENCES public.patients(id);
      SQL
    end

    include_context 'with test compiler'

    it 'renders the join the foreign key describes' do
      test_compiler.write('schema', generated)
      test_compiler.compiler.require('schema')
      test_compiler.write('app', <<~JADE)
        module App exposing (go)

        import Sql exposing (Table)
        import Sql.Query exposing (Select, field, from, join, select)
        import Schema exposing (PatientsOn(..), patients, visits)


        struct Row = {
          a: Int,
          b: Int
        }


        def go -> Select(Row)
          p <- from(patients)
          v <- visits |> join(p |> patients.on.visits)

          select(Row(_, _))
            |> field(p.id)
            |> field(v.id)
        end
      JADE
      test_compiler.compiler.require('app')

      expect(Sql::Query.to_sql(App.go)[0]).to eql(
        'SELECT patients.id, visits.id FROM patients patients ' \
        'INNER JOIN visits visits ON patients.id = visits.patient_id',
      )
    end
  end

  describe 'enums' do
    include_context 'with test compiler'

    let(:sql) do
      <<~SQL
        CREATE TYPE public.invoice_status AS ENUM ('pending', 'paid');
        CREATE TYPE public.card_status AS ENUM ('pending', 'active');
        CREATE TYPE public.currency AS ENUM ('usd', 'eur');

        CREATE TABLE public.invoices (
            id bigint NOT NULL,
            status public.invoice_status NOT NULL,
            paid_in public.currency NOT NULL
        );

        CREATE TABLE public.cards (
            id bigint NOT NULL,
            status public.card_status NOT NULL
        );
      SQL
    end

    it 'gives each enum a module, since a table does not own one' do
      expect(modules.keys).to contain_exactly(
        'Schema', 'Schema.InvoiceStatus', 'Schema.CardStatus', 'Schema.Currency'
      )
    end

    it 'names the type after the SQL type, guessing nothing' do
      expect(modules.fetch('Schema.InvoiceStatus')).to include(<<~JADE.strip)
        type InvoiceStatus
          = Pending
          | Paid
      JADE
    end

    # A derived codec reads the constructor and writes its snake_case, which
    # is the label only when the label was lowercase. The written one carries
    # what the DDL says.
    it 'writes a codec over the labels themselves' do
      expect(modules.fetch('Schema.InvoiceStatus')).to include(<<~JADE.strip)
        def encode_invoice_status(v: InvoiceStatus) -> Value
          case v
          in Pending then Encode.string("pending")
          in Paid then Encode.string("paid")
          end
        end
      JADE
    end

    it 'types the column through the module it imports' do
      expect(generated).to include('import Schema.InvoiceStatus as InvoiceStatus')
      expect(generated).to include('status: Expr(InvoiceStatus.InvoiceStatus)')
    end

    it 'compiles, though both enums have a pending label' do
      modules
        .sort_by { |name, _| -name.count('.') }
        .each do |name, source|
          described_class
            .module_path(root_module, name, 'schema.jd')
            .then { test_compiler.require(it.delete_suffix('.jd'), source) }
        end
    end
  end
  # A label is whatever the DDL says, and currency codes are the common case
  # of one that is not the snake_case of any constructor. A derived codec
  # would write `usd` into a column that only accepts `USD`.
  context 'an enum whose labels are not lowercase' do
    let(:sql) do
      <<~SQL
        CREATE TYPE public.currency AS ENUM ('USD', 'EUR');

        CREATE TABLE public.prices (
            id bigint NOT NULL,
            paid_in public.currency NOT NULL
        );
      SQL
    end

    include_context 'with test compiler'

    it 'round-trips the label the column holds' do
      described_class.generate(sql)
        .sort_by { |name, _| -name.count('.') }
        .each do |name, source|
          described_class
            .module_path('Schema', name, 'schema.jd')
            .delete_suffix('.jd')
            .then { test_compiler.write(it, source); test_compiler.compiler.require(it) }
        end

      test_compiler.write('probe', <<~JADE)
        module Probe exposing (written)

        import Schema.Currency as Currency exposing (Currency(..))
        import Decode exposing (Value)
        import Encode


        def written -> Value
          Encode.encode(Usd)
        end
      JADE
      test_compiler.compiler.require('probe')

      expect(Probe.written).to eql 'USD'
    end
  end
end
