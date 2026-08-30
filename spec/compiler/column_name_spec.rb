require 'spec_helper'

require 'jade-sql'
require 'jade-sql/bin/generate_schema'

module JadeSql
  # The generator renames a column into a field and the compiler renames it
  # back. Nothing at runtime compares the two, so the round trip is checked
  # here: a column the check cannot recover is one the deriver would write
  # under a name the table does not have.
  describe 'column name round trip' do
    def round_trip(column)
      Compiler.column_name(SchemaGenerator.send(:field_name, column))
    end

    it 'recovers every jade keyword' do
      Jade::Lexer::KEYWORDS.each do |keyword|
        expect(round_trip(keyword)).to eql keyword
      end
    end

    it 'leaves an ordinary column alone' do
      expect(round_trip('balance')).to eql 'balance'
    end

    # `total_` is a column name in its own right, not a renamed `total`.
    it 'keeps a trailing underscore that was not the generator putting one there' do
      expect(round_trip('total_')).to eql 'total_'
    end
  end
end
