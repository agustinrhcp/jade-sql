require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'

module JadeSql
  describe 'checking a written struct against its table' do
    include_context 'with test compiler'

    def app(struct_fields, call)
      <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (Col(..), Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
import Sql.Write exposing (Write, insert, insert_all, update)


#{jade_table('patients', { id: 'Int', name: 'String', balance: 'Maybe(Int)' }, pk: 'patients_pk')}


struct Patient = {
#{struct_fields}
}


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def go -> Write(Int, PatientsCols)
  #{call}
end
      JADE
    end

    let(:good_fields) { "  name: String,\n  balance: Maybe(Int)" }
    let(:bad_fields) { "  nmae: String,\n  balance: Maybe(Int)" }
    let(:mistyped_fields) { "  name: Int,\n  balance: Maybe(Int)" }
    let(:no_name_fields) { "  id: Int,\n  balance: Maybe(Int)" }

    it 'accepts a struct whose fields are all columns of the table' do
      expect { test_compiler.require('app', app(good_fields, 'insert(Patient("Ada", Just(1)), patients)')) }
        .not_to raise_error
    end

    it 'names the field the table has no column for' do
      expect { test_compiler.require('app', app(bad_fields, 'insert(Patient("Ada", Just(1)), patients)')) }
        .to raise_error(/Patient\.nmae has no column on PatientsCols/)
    end

    it 'reports a field whose type is not the column type' do
      expect { test_compiler.require('app', app(mistyped_fields, 'insert(Patient(1, Just(1)), patients)')) }
        .to raise_error(/name is String, but Patient\.name is Int/)
    end

    it 'checks the element type of insert_all' do
      expect { test_compiler.require('app', app(bad_fields, 'insert_all([Patient("Ada", Just(1))], patients)')) }
        .to raise_error(/nmae has no column/)
    end

    it 'checks update the same way, past the key argument' do
      expect { test_compiler.require('app', app(bad_fields, 'update(Patient("Ada", Just(1)), patients, 1)')) }
        .to raise_error(/nmae has no column/)
    end

    it 'names the required column the struct leaves for Postgres to reject' do
      expect { test_compiler.require('app', app(no_name_fields, 'insert(Patient(1, Just(1)), patients)')) }
        .to raise_error(/Patient does not write `name`, which PatientsCols requires/)
    end

    it 'leaves update alone, since the row it writes to already has them' do
      expect { test_compiler.require('app', app(no_name_fields, 'update(Patient(1, Just(1)), patients, 1)')) }
        .not_to raise_error
    end

    context 'a table whose timestamps the database will not fill' do
      def stamps_app(call)
        <<~JADE.strip
module App exposing (go)

import Clock exposing (Instant)
import Encode
import Sql exposing (Col(..), Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
import Sql.Write exposing (Write, insert, timestamped)


#{jade_table(
  'patients',
  { id: 'Int', name: 'String', created_at: 'Instant', updated_at: 'Instant' },
  pk: 'patients_pk',
)}


struct Patient = { name: String }


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def go -> Write(Int, PatientsCols)
  #{call}
end
        JADE
      end

      it 'points at timestamped rather than asking for two fields nobody writes' do
        expect { test_compiler.require('app', stamps_app('insert(Patient("Ada"), patients)')) }
          .to raise_error(/does not write `created_at` and `updated_at`/)
      end

      it 'takes timestamped as writing them' do
        expect { test_compiler.require('app', stamps_app('insert(Patient("Ada") |> timestamped, patients)')) }
          .not_to raise_error
      end
    end

    context 'assigning to something that is not a column' do
      let(:not_a_column) do
        <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (
  Assignment,
  Col(..),
  Expr,
  NoJoins,
  NoRequiredCols,
  Pk,
  Table,
  coalesce,
  column,
  no_joins,
  pk,
  set,
  table,
)
import Sql.Write exposing (Write, update_all)


#{jade_table('patients', { id: 'Int', nickname: 'Maybe(String)' }, pk: 'patients_pk')}


def patients_pk -> Pk(PatientsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def go -> Write(Int, PatientsCols)
  update_all(
    patients,
    (c) -> { c.id |> eq(1) },
    (c, s) -> { [coalesce(c.nickname, "x") |> set("y")] },
  )
end
        JADE
      end

      # `set` used to recover the column name by splitting the rendered SQL on
      # a dot, so this produced `SET nickname, ?) = ?` and nobody found out
      # until Postgres did.
      it 'will not take an expression where a column belongs' do
        expect { test_compiler.require('app', not_a_column) }
          .to raise_error(Jade::CompilationError)
      end
    end

    context 'a table the database can fill on its own' do
      let(:no_required_app) do
        <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (
  Col(..),
  Expr,
  NoJoins,
  NoRequiredCols,
  Pk,
  Table,
  column,
  no_joins,
  pk,
  table,
)
import Sql.Write exposing (Write, insert)


#{jade_table('events', { id: 'Int', note: 'Maybe(String)' }, pk: 'events_pk')}


struct Event = { note: Maybe(String) }


def events_pk -> Pk(EventsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def go -> Write(Int, EventsCols)
  insert(Event(Nothing), events)
end
        JADE
      end

      it 'requires nothing, since NoRequiredCols names no columns' do
        expect { test_compiler.require('app', no_required_app) }.not_to raise_error
      end
    end

    context 'a column renamed to dodge a jade keyword' do
      let(:reserved_app) do
        <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (Col(..), Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
import Sql.Write exposing (Write, insert)


#{jade_table('entries', { type_: 'String' })}


struct Entry = { type_: String }


def go -> Write(Int, EntriesCols)
  insert(Entry("debit"), entries)
end
        JADE
      end

      it 'matches the field against the column it was renamed from' do
        expect { test_compiler.require('app', reserved_app) }.not_to raise_error
      end
    end

    context 'a generic helper wrapping insert' do
      let(:wrapped_app) do
        <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (Col(..), Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
import Sql.Write exposing (Write, insert)


#{jade_table('patients', { name: 'String' })}


struct Patient = { nmae: String }


def save(v: a, t: Table(c, m, k, o, r, s)) -> Write(Int, c)
  insert(v, t)
end


def go -> Write(Int, PatientsCols)
  save(Patient("Ada"), patients)
end
        JADE
      end

      # The check reads the types at the call it can see. Inside `save` both
      # are still variables, and at `save` the callee is not one of jade-sql's
      # entry points — so wrapping opts out, quietly and by design.
      it 'stays quiet, since neither call site has both types' do
        expect { test_compiler.require('app', wrapped_app) }.not_to raise_error
      end
    end
    context 'a struct whose Assignable is written by hand' do
      let(:polymorphic_app) do
        <<~JADE.strip
module App exposing (go)

import Encode
import Sql exposing (
  Assignable,
  Assignment,
  Col(..),
  Expr,
  NoJoins,
  Pk,
  Table,
  assign,
  column,
  no_joins,
  pk,
  table,
)
import Sql.Write exposing (Write, insert)


#{jade_table('invoices', { payer_type: 'String', payer_id: 'Int' })}


type Payer
  = Patient(Int)
  | Company(Int)


struct NewInvoice = { payer: Payer }


implements Assignable(NewInvoice) with
  to_assigns: invoice_assigns
end


def invoice_assigns(i: NewInvoice) -> List(Assignment)
  [
    assign("payer_type", payer_type(i.payer)),
    assign("payer_id", payer_id(i.payer)),
  ]
end


def payer_type(p: Payer) -> String
  case p
  in Patient(_) then "Patient"
  in Company(_) then "Company"
  end
end


def payer_id(p: Payer) -> Int
  case p
  in Patient(id) then id
  in Company(id) then id
  end
end


def go -> Write(Int, InvoicesCols)
  insert(NewInvoice(Patient(7)), invoices)
end
        JADE
      end

      # `payer` becomes two columns, which is what a polymorphic reference is.
      # The author said so in `to_assigns`; the check has nothing to add.
      it 'says nothing about a field that maps to no column of its own name' do
        expect { test_compiler.require('app', polymorphic_app) }.not_to raise_error
      end
    end

  end
end
