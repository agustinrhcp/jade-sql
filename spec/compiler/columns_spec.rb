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
        import Sql exposing (Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
        import Sql.Mutation exposing (Mutation, insert, insert_all, update)


        struct PatientsCols = {
          id: Expr(Int),
          name: Expr(String),
          balance: Expr(Maybe(Int))
        }


        struct MaybePatientsCols = {
          id: Expr(Maybe(Int)),
          name: Expr(Maybe(String)),
          balance: Expr(Maybe(Int))
        }


        struct Patient = {
        #{struct_fields}
        }


        def patients_pk -> Pk(PatientsCols, Int)
          pk(["id"], (v) -> { [Encode.encode(v)] })
        end


        def patients -> Table(PatientsCols, MaybePatientsCols, Int, NoJoins)
          table(
            "patients",
            "patients",
            (a) -> { PatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            (a) -> { MaybePatientsCols(column(a, "id"), column(a, "name"), column(a, "balance")) },
            patients_pk,
            no_joins,
          )
        end


        def go -> Mutation(Int, PatientsCols)
          #{call}
        end
      JADE
    end

    let(:good_fields) { "  name: String,\n  balance: Maybe(Int)" }
    let(:bad_fields) { "  nmae: String,\n  balance: Maybe(Int)" }
    let(:mistyped_fields) { "  name: Int,\n  balance: Maybe(Int)" }

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

    context 'a column renamed to dodge a jade keyword' do
      let(:reserved_app) do
        <<~JADE.strip
          module App exposing (go)

          import Encode
          import Sql exposing (Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
          import Sql.Mutation exposing (Mutation, insert)


          struct EntriesCols = { type_: Expr(String) }


          struct MaybeEntriesCols = { type_: Expr(Maybe(String)) }


          struct Entry = { type_: String }


          def entries -> Table(EntriesCols, MaybeEntriesCols, Int, NoJoins)
            table(
              "entries",
              "entries",
              (a) -> { EntriesCols(column(a, "type")) },
              (a) -> { MaybeEntriesCols(column(a, "type")) },
              pk(["id"], (v) -> { [Encode.encode(v)] }),
              no_joins,
            )
          end


          def go -> Mutation(Int, EntriesCols)
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
          import Sql exposing (Expr, NoJoins, Pk, Table, column, no_joins, pk, table)
          import Sql.Mutation exposing (Mutation, insert)


          struct PatientsCols = { name: Expr(String) }


          struct MaybePatientsCols = { name: Expr(Maybe(String)) }


          struct Patient = { nmae: String }


          def patients -> Table(PatientsCols, MaybePatientsCols, Int, NoJoins)
            table(
              "patients",
              "patients",
              (a) -> { PatientsCols(column(a, "name")) },
              (a) -> { MaybePatientsCols(column(a, "name")) },
              pk(["id"], (v) -> { [Encode.encode(v)] }),
              no_joins,
            )
          end


          def save(v: a, t: Table(c, m, k, o)) -> Mutation(Int, c)
            insert(v, t)
          end


          def go -> Mutation(Int, PatientsCols)
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
          import Sql.Mutation exposing (Mutation, insert)


          struct InvoicesCols = {
            payer_type: Expr(String),
            payer_id: Expr(Int)
          }


          struct MaybeInvoicesCols = {
            payer_type: Expr(Maybe(String)),
            payer_id: Expr(Maybe(Int))
          }


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


          def invoices -> Table(InvoicesCols, MaybeInvoicesCols, Int, NoJoins)
            table(
              "invoices",
              "invoices",
              (a) -> { InvoicesCols(column(a, "payer_type"), column(a, "payer_id")) },
              (a) -> { MaybeInvoicesCols(column(a, "payer_type"), column(a, "payer_id")) },
              pk(["id"], (v) -> { [Encode.encode(v)] }),
              no_joins,
            )
          end


          def go -> Mutation(Int, InvoicesCols)
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
