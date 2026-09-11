require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'the error a failed statement comes back as', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    let(:source) do
      <<~JADE
module App exposing (name_a_visit, orphan_visit, overdrawn_patient)

import Sql exposing (SqlError, execute_raw)


def orphan_visit -> Task(Int, SqlError)
  execute_raw(("INSERT INTO visits (patient_id) VALUES (999)", []))
end


def name_a_visit -> Task(Int, SqlError)
  execute_raw(("INSERT INTO patients (balance) VALUES (1)", []))
end


def overdrawn_patient -> Task(Int, SqlError)
  execute_raw(("INSERT INTO patients (name, balance) VALUES ('Ada', -1)", []))
end
      JADE
    end

    before { test_compiler.require('app', source) }

    def conn = JadeSql::TestDb.connection

    it 'names the foreign key a write violated' do
      status, error = App.orphan_visit

      expect(status).to eql "err"
      expect(error.first).to eql "ForeignKeyViolation"
      expect(error.last).to include "patient_id"
    end

    it 'names the column a write left null' do
      expect(App.name_a_visit).to eql ["err", ["NotNullViolation", "name"]]
    end

    it 'names the check constraint a write violated' do
      conn.execute(<<~SQL)
        ALTER TABLE patients ADD CONSTRAINT patients_balance_positive CHECK (balance >= 0)
      SQL

      expect(App.overdrawn_patient)
        .to eql ["err", ["CheckViolation", "patients_balance_positive"]]
    ensure
      conn.execute("ALTER TABLE patients DROP CONSTRAINT patients_balance_positive")
    end
  end
end
