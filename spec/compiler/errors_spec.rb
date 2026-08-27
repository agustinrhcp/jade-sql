require 'spec_helper'

require 'jade-sql'

module JadeSql
  describe Compiler::Errors::UnknownColumn do
    subject(:error) do
      described_class.new(
        'App', nil,
        struct: 'Patient', field: :nmae, table: 'PatientsCols',
        columns: %w[id name balance],
      )
    end

    it 'reads as the struct field it could not place' do
      expect(error.message).to eql 'Patient.nmae has no column on PatientsCols'
    end

    # The columns are right there. A typo should not send anyone to the schema
    # to work out what they meant.
    it 'offers the columns as spelling candidates' do
      expect(Jade::DidYouMean.suggest(error.queried_name, error.candidates))
        .to eql ['name']
    end
  end
end
