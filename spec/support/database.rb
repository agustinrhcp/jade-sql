# Postgres-backed integration harness. ActiveRecord is loaded lazily so the
# pure compile/render specs don't pay for it. Point at a different database
# with JADE_SQL_TEST_DB / PGHOST.
#
# Include `with database` in a group to get a connected, empty schema per
# example, with task dispatch in loose mode so the real JadeSql::Runtime
# ports fire (instead of being stubbed).
module JadeSql
  module TestDb
    extend self

    TABLES = %w[patients].freeze

    SCHEMA_SQL = <<~SQL.freeze
      CREATE TABLE patients (
        id         serial PRIMARY KEY,
        name       text             NOT NULL,
        balance    integer          NOT NULL DEFAULT 0,
        rate       numeric(6,4)     NOT NULL DEFAULT 0,
        weight     double precision NOT NULL DEFAULT 0,
        tags       text[]           NOT NULL DEFAULT '{}',
        rules      jsonb            NOT NULL DEFAULT '{}',
        created_at timestamp,
        updated_at timestamp
      );
    SQL

    def setup!
      return if @setup

      require 'active_record'
      ::ActiveRecord::Base.establish_connection(
        adapter: 'postgresql',
        database: ENV.fetch('JADE_SQL_TEST_DB', 'jade_sql_test'),
        host: ENV.fetch('PGHOST', '/tmp'),
      )
      connection.execute("DROP TABLE IF EXISTS patients")
      connection.execute(SCHEMA_SQL)
      @setup = true
    end

    def truncate!
      connection.execute("TRUNCATE #{TABLES.join(', ')} RESTART IDENTITY CASCADE")
    end

    def connection = ::ActiveRecord::Base.connection
  end
end

RSpec.shared_context 'with database' do
  before(:all) { JadeSql::TestDb.setup! }

  before(:each) do
    Jade::Tasks.reset!(strict: false)
    JadeSql::TestDb.truncate!
  end
end
