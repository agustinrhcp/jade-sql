require 'spec_helper'

require 'active_record'
require 'jade-sql'
require 'jade-sql/runtime'

describe JadeSql::Runtime do
  describe '.translate' do
    def translate(error)
      described_class.translate(error)
    end

    it 'names each constraint violation' do
      expect(translate(::ActiveRecord::RecordNotUnique.new('x')).first).to eql 'UniqueViolation'
      expect(translate(::ActiveRecord::InvalidForeignKey.new('x')).first).to eql 'ForeignKeyViolation'
      expect(translate(::ActiveRecord::CheckViolation.new('x')).first).to eql 'CheckViolation'
      expect(translate(::ActiveRecord::ExclusionViolation.new('x')).first).to eql 'ExclusionViolation'
      expect(translate(::ActiveRecord::NotNullViolation.new('x')).first).to eql 'NotNullViolation'
    end

    it 'names a transaction that lost, and a statement that ran out of time' do
      expect(translate(::ActiveRecord::Deadlocked.new('x'))).to eql ['Deadlock']
      expect(translate(::ActiveRecord::SerializationFailure.new('x'))).to eql ['SerializationFailure']
      expect(translate(::ActiveRecord::QueryCanceled.new('x'))).to eql ['StatementTimeout']
      expect(translate(::ActiveRecord::LockWaitTimeout.new('x'))).to eql ['LockTimeout']
    end

    it 'keeps the message for anything it does not name' do
      expect(translate(::ActiveRecord::StatementInvalid.new('syntax error')))
        .to eql ['DbError', 'syntax error']
    end

    # The name comes off the PG diagnostics; an adapter that reports none
    # leaves the variant with an empty name rather than no variant.
    it 'carries an empty name when the adapter reports none' do
      expect(translate(::ActiveRecord::RecordNotUnique.new('x'))).to eql ['UniqueViolation', '']
    end
  end
end
