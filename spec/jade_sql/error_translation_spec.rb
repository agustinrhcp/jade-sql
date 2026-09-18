require 'spec_helper'

require 'active_record'
require 'jade-sql'
require 'jade-sql/runtime'

describe JadeSql::Runtime do
  describe '.translate' do
    # Built the way the adapter hands it over, since Rails 7 has no class for
    # two of these.
    def pg_error(sqlstate, fields = {})
      result = instance_double(PG::Result)
      allow(result).to receive(:error_field) do |field|
        { PG::Result::PG_DIAG_SQLSTATE => sqlstate }.merge(fields)[field]
      end

      cause = instance_double(PG::Error, result: result)
      error = ActiveRecord::StatementInvalid.new('the adapter said something')
      allow(error).to receive(:cause).and_return(cause)
      error
    end

    def translate(error)
      described_class.translate(error)
    end

    it 'names each constraint violation, with the constraint Postgres reported' do
      named = { PG::Result::PG_DIAG_CONSTRAINT_NAME => 'users_email_key' }

      expect(translate(pg_error('23505', named))).to eql ['UniqueViolation', 'users_email_key']
      expect(translate(pg_error('23503', named))).to eql ['ForeignKeyViolation', 'users_email_key']
      expect(translate(pg_error('23514', named))).to eql ['CheckViolation', 'users_email_key']
      expect(translate(pg_error('23P01', named))).to eql ['ExclusionViolation', 'users_email_key']
    end

    it 'carries the column for a not-null violation, which names no constraint' do
      column = { PG::Result::PG_DIAG_COLUMN_NAME => 'email' }

      expect(translate(pg_error('23502', column))).to eql ['NotNullViolation', 'email']
    end

    it 'names a transaction that lost, and a statement that ran out of time' do
      expect(translate(pg_error('40P01'))).to eql ['Deadlock']
      expect(translate(pg_error('40001'))).to eql ['SerializationFailure']
      expect(translate(pg_error('57014'))).to eql ['StatementTimeout']
      expect(translate(pg_error('55P03'))).to eql ['LockTimeout']
    end

    it 'carries an empty name when Postgres reports none' do
      expect(translate(pg_error('23505'))).to eql ['UniqueViolation', '']
    end

    it 'keeps the message for a SQLSTATE it does not name' do
      expect(translate(pg_error('42601'))).to eql ['DbError', 'the adapter said something']
    end

    it 'keeps the message for an error that never reached Postgres' do
      expect(translate(ActiveRecord::StatementInvalid.new('connection refused')))
        .to eql ['DbError', 'connection refused']
    end
  end
end
