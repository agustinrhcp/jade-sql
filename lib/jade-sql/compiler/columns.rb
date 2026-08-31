module JadeSql
  module Compiler
    # A struct's fields map onto a table's columns by name, and the mapping
    # derives, so nothing else ever compares the two — a field the table has
    # no column for reaches Postgres as invalid SQL. Both types are concrete
    # at the call site, which is why this is a check and not a constraint.
    module Columns
      extend self
      include Helpers

      TABLE = 'Sql.Table'
      EXPR = 'Sql.Expr'
      LIST = 'List.List'
      ASSIGNABLE = 'Sql.Assignable'
      STAMPED = 'Sql.Mutation.Stamped'
      STAMPS = %w[created_at updated_at].freeze

      # Where the written value is, where the table is, whether the value
      # arrives wrapped in a list, and whether the row is being created —
      # only then does a column the database cannot fill have to be written.
      Target = Data.define(:value_at, :table_at, :wrapper, :creates)

      TARGETS = {
        'Sql.Mutation.insert' => Target[0, 1, :bare, true],
        'Sql.Mutation.insert_all' => Target[0, 1, :list, true],
        'Sql.Mutation.update' => Target[0, 1, :bare, false],
      }.freeze

      def watches = TARGETS.keys

      def check(ctx)
        TARGETS.fetch(ctx.name).then do |target|
          table = ctx.arg_types[target.table_at]
          value, stamps = unstamp(unwrap(ctx.arg_types[target.value_at], target.wrapper))

          next [] if written?(value, ctx.registry)

          compare(value, cols_of(table), ctx) +
            (target.creates ? missing(value, stamps, table, ctx) : [])
        end
      end

      private

      # A field maps to the column of the same name only because the deriver
      # says so. An author who wrote `to_assigns` by hand has already said
      # what the columns are — one field may become two, or none — so there
      # is nothing here to compare against.
      def written?(value, registry)
        case implementation(value, registry)
        in Symbol::Implementation(module_name: String) then true
        else false
        end
      end

      def implementation(value, registry)
        case value
        in Type::Application(constructor: Type::Constructor(name:))
          registry.implementations[[ASSIGNABLE, name]]

        else nil
        end
      end

      # `r` names the columns the database will not fill in, so a value that
      # writes none of them produces a row Postgres rejects. `stamped` writes
      # two of them without them being fields, which is why it is carried
      # alongside the value's own.
      def missing(value, stamps, table, ctx)
        case [fields_of(value, ctx.registry), columns_of(required_of(table), ctx.registry)]
        in [Array => fields, Hash => required]
          required.keys - fields.map { Compiler.column_name(it.first) } - stamps

        else []
        end
          .then do |absent|
            next [] if absent.empty?

            [Errors::MissingColumns.new(
              ctx.entry_name, ctx.span,
              struct: name_of(value), table: name_of(cols_of(table)), missing: absent,
            )]
          end
      end

      # `Table(c, m, k, o, r)` — the required columns are its last argument.
      def required_of(table)
        case table
        in Type::Application(constructor: Type::Constructor(name: TABLE), args: [*, required])
          required

        else nil
        end
      end

      # `stamped` writes `created_at` and `updated_at` on a value that has no
      # such fields, so it answers for them without appearing among them.
      def unstamp(value)
        case value
        in Type::Application(constructor: Type::Constructor(name: STAMPED), args: [inner])
          [inner, STAMPS]

        else [value, []]
        end
      end

      # Either side may be absent — an argument the caller left off, a table
      # still polymorphic in its columns — and then there is nothing to compare.
      def compare(value, cols, ctx)
        case [fields_of(value, ctx.registry), columns_of(cols, ctx.registry)]
        in [Array => fields, Hash => columns]
          fields.filter_map { mismatch(it, columns, value, cols, ctx) }

        else []
        end
      end

      def mismatch((name, type), columns, value, cols, ctx)
        column = Compiler.column_name(name)

        case columns[column]
        in nil
          Errors::UnknownColumn.new(
            ctx.entry_name, ctx.span,
            struct: name_of(value), field: name, table: name_of(cols),
            columns: columns.keys,
          )

        in ^type
          nil

        in found
          Errors::ColumnTypeMismatch.new(
            ctx.entry_name, ctx.span,
            struct: name_of(value), field: name, table: name_of(cols),
            column:, expected: found, actual: type,
          )
        end
      end

      # `Table(c, m, k, ...)` — the columns are its first argument.
      def cols_of(table)
        case table
        in Type::Application(constructor: Type::Constructor(name: TABLE), args: [cols, *])
          cols

        else nil
        end
      end

      # Each column is an `Expr(t)` whose `t` is what the field has to be.
      def columns_of(cols, registry)
        fields_of(cols, registry)
          &.to_h { |field, type| [Compiler.column_name(field), unwrap_expr(type)] }
      end

      def fields_of(type, registry)
        case type
        in Type::Application(constructor: Type::Constructor(name:), args:)
          Symbol
            .type_ref_from_qualified_name(name)
            .then { registry.lookup(it) }
            .then { (it in Symbol::Struct) ? struct_fields(it, args, registry) : nil }

        else nil
        end
      end

      def unwrap(type, wrapper)
        case [wrapper, type]
        in [:list, Type::Application(constructor: Type::Constructor(name: LIST), args: [inner])]
          inner

        else type
        end
      end

      def unwrap_expr(type)
        case type
        in Type::Application(constructor: Type::Constructor(name: EXPR), args: [inner])
          inner

        else type
        end
      end

      def name_of(type)
        case type
        in Type::Application(constructor: Type::Constructor(name:), args: _)
          name.split('.').last

        else type.to_s
        end
      end
    end
  end
end
