module JadeSql
  module Compiler
    module Assignable
      extend self
      include Helpers

      INTERFACE = 'Sql.Assignable'
      ASSIGNMENT = 'Sql.Assignment'
      ASSIGNMENT_FIELDS = %w[col value_sql params].freeze

      def supports?(interface) = interface == INTERFACE

      def derive(constraint, registry, entry_name, &lookup)
        return failed(constraint, entry_name) unless assignment_matches?(registry)

        case constraint.type
        in Type::Application(constructor: Type::Constructor(name:), args:)
          Symbol
            .type_ref_from_qualified_name(name)
            .then { registry.lookup(it) }
            .then { derive_for(constraint, it, args, registry, lookup, entry_name) }

        else
          failed(constraint, entry_name)
        end
      end

      private

      # The interface is matched by name, so some other module called `Sql`
      # would otherwise be derived against as though it were jade-sql.
      def assignment_matches?(registry)
        Symbol
          .type_ref_from_qualified_name(ASSIGNMENT)
          .then { registry.lookup(it) }
          .then do
            it in Symbol::Struct(record_type: { fields: }) and
              fields.keys.map(&:to_s) == ASSIGNMENT_FIELDS
          end
      end

      def derive_for(constraint, symbol, args, registry, lookup, entry_name)
        case symbol
        in Symbol::Union if args.empty? && single_payload?(symbol, registry)
          derive_union(constraint, symbol, registry, lookup, entry_name)

        in Symbol::Struct
          derive_struct(constraint, symbol, args, registry, lookup, entry_name)

        else
          failed(constraint, entry_name)
        end
      end

      # One column per variant, so each variant carries exactly the value
      # that column is set to.
      def single_payload?(union_sym, registry)
        variants(union_sym, registry)
          .then { it.any? && it.all? { it.args.size == 1 } }
      end

      def derive_union(constraint, union_sym, registry, lookup, entry_name)
        vs = variants(union_sym, registry)

        vs
          .map { encodable_dep(it, registry) }
          .map { lookup.call(it) }
          .then { Results.sequence(it) }
          .map { assignable(constraint, union_body(vs), it) }
      end

      def derive_struct(constraint, struct_sym, args, registry, lookup, entry_name)
        fields = struct_fields(struct_sym, args, registry)

        fields
          .map { |_, type| Type.constraint('Encode.Encodable', type, nil) }
          .map { lookup.call(it) }
          .then { Results.sequence(it) }
          .map { assignable(constraint, struct_body(fields), it) }
      end

      def struct_body(fields)
        fields
          .each_with_index
          .map { |(name, _), idx| field_assignment(name, idx) }
          .then { [:list, it] }
      end

      def field_assignment(name, idx)
        [:call,
          [:struct_constructor, ASSIGNMENT, 3],
          [
            Compiler.column_name(name),
            '?',
            [:list,
              [[:call, [:impl_arg, idx, 'encoder'], [[:access, [:var, 'f'], name.to_s]]]],
            ],
          ],
        ]
      end

      def encodable_dep(variant, registry)
        variant
          .args
          .first
          .then { instantiate(it, {}, registry) }
          .then { Type.constraint('Encode.Encodable', it, nil) }
      end

      def union_body(variants)
        variants
          .each_with_index
          .map { |v, idx| [[:constructor, v.qualified_name, ['x']], [assignment(v, idx)]] }
          .then { [:case, [:var, 'f'], it] }
      end

      def assignment(variant, idx)
        [:call,
          [:struct_constructor, ASSIGNMENT, 3],
          [
            wire_name(variant),
            '?',
            [:list, [[:call, [:impl_arg, idx, 'encoder'], [[:var, 'x']]]]],
          ],
        ]
          .then { [:list, [it]] }
      end

      def failed(constraint, entry_name)
        Err[
          DerivationFailed.new(
            entry_name, constraint.origin&.range, constraint:, trace: [],
          )
        ]
      end

      def assignable(constraint, body, deps)
        implementation(
          constraint,
          { 'to_assigns' => Symbol::DerivedFunction.new(params: ['f'], body:) },
          deps:,
        )
      end
    end
  end
end
