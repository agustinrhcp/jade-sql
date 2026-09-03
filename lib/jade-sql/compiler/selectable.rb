module JadeSql
  module Compiler
    # `Selectable(a)` is the read side of `Assignable(a)`: the fields of the
    # shape you asked for become the columns selected, so a straightforward
    # read needs no `select` at all.
    #
    # Only the names are derived. The values decode through the port's own
    # `Decodable(a)`, which already reads a row by field name.
    module Selectable
      extend self
      include Helpers

      INTERFACE = 'Sql.Selectable'
      SELECTOR = 'Sql.Selector'

      def supports?(interface) = interface == INTERFACE

      def derive(constraint, registry, entry_name, &_lookup)
        case constraint.type
        in Type::AnonymousRecord(fields:)
          Ok[selectable(constraint, fields.keys)]

        in Type::Application(constructor: Type::Constructor(name:), args:)
          Symbol
            .type_ref_from_qualified_name(name)
            .then { registry.lookup(it) }
            .then { derive_named(constraint, it, args, registry, entry_name) }

        else
          failed(constraint, entry_name)
        end
      end

      private

      def derive_named(constraint, symbol, args, registry, entry_name)
        case symbol
        in Symbol::Struct
          struct_fields(symbol, args, registry)
            .map(&:first)
            .then { Ok[selectable(constraint, it)] }

        else
          failed(constraint, entry_name)
        end
      end

      def selectable(constraint, names)
        implementation(
          constraint,
          { 'selector' => Symbol::DerivedFunction.new(params: [], body: body(names)) },
        )
      end

      # `Selector(columns, params)`: no params, because a column list carries
      # no values to bind.
      def body(names)
        [:call,
          [:struct_constructor, SELECTOR, 2],
          [
            [:list, names.map { Compiler.column_name(it) }],
            [:list, []],
          ],
        ]
      end

      def failed(constraint, entry_name)
        Err[
          DerivationFailed.new(
            entry_name, constraint.origin&.range, constraint:, trace: [],
          )
        ]
      end
    end
  end
end
