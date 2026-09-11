module JadeSql
  module Compiler
    # A read derives its columns from the shape it is asked for, so that
    # shape's fields and the table's columns are two lists nothing compares
    # unless this does. Same job as `Columns` does for a write, from the
    # other end of the call: what is checked there arrives as an argument,
    # and here it is what the call returns.
    module Selected
      extend self
      include Helpers

      TASK = 'Task.Task'
      LIST = 'List.List'
      QUERY = 'Sql.Query.Query'
      SELECTOR = 'Sql.Selector'

      READERS = {
        'Sql.Query.fetch_row' => :task,
        'Sql.Query.fetch_rows' => :task_list,
        'Sql.Query.selected' => :query,
      }.freeze

      def watches = READERS.keys

      def check(ctx)
        [row_type(ctx.return_type, READERS.fetch(ctx.name)), columns(ctx)]
          .then { |row, columns| compare(row, columns, ctx) }
      end

      private

      def compare(row, columns, ctx)
        return [] if columns.nil?
        return [undecided(ctx)] if row in Type::Var

        case fields_of(row, ctx.registry)
        in Array => fields then fields.filter_map { mismatch(it, columns, row, ctx) }
        else []
        end
      end

      def columns(ctx)
        case ctx.arg_types.first
        in Type::Application(constructor: Type::Constructor(name: QUERY), args: [cols])
          columns_of(cols, ctx.registry)

        else nil
        end
      end

      def row_type(type, shape)
        case [shape, type]
        in [:task, Type::Application(constructor: Type::Constructor(name: TASK), args: [row, _])]
          row

        in [:task_list, Type::Application(
          constructor: Type::Constructor(name: TASK),
          args: [Type::Application(constructor: Type::Constructor(name: LIST), args: [row]), _],
        )]
          row

        in [:query, Type::Application(
          constructor: Type::Constructor(name: QUERY),
          args: [Type::Application(constructor: Type::Constructor(name: SELECTOR), args: [row])],
        )]
          row

        else nil
        end
      end

      def mismatch((name, type), columns, row, ctx)
        column = Compiler.column_name(name)

        return undecided_field(name, column, columns, ctx) if type in Type::Var

        case columns[column]
        in nil
          Errors::UnknownColumn.new(
            ctx.entry_name, ctx.span,
            struct: name_of(row), field: name, table: 'this table',
            columns: columns.keys,
          )

        in ^type
          nil

        in found
          Errors::ColumnTypeMismatch.new(
            ctx.entry_name, ctx.span,
            struct: name_of(row), field: name, table: 'this table',
            column:, expected: found, actual: type,
          )
        end
      end

      def undecided_field(name, column, columns, ctx)
        return nil if columns[column].nil?

        Errors::UndecidedField.new(
          ctx.entry_name, ctx.span, field: name, column:, type: columns[column],
        )
      end

      def undecided(ctx)
        Errors::UndecidedShape.new(ctx.entry_name, ctx.span, reader: ctx.name.split('.').last)
      end

      def fields_of(type, registry)
        case type
        in Type::AnonymousRecord(fields:) then fields.to_a

        in Type::Application(constructor: Type::Constructor(name:), args:)
          Symbol
            .type_ref_from_qualified_name(name)
            .then { registry.lookup(it) }
            .then { (it in Symbol::Struct) ? struct_fields(it, args, registry) : nil }

        else nil
        end
      end

      def columns_of(cols, registry)
        fields_of(cols, registry)
          &.to_h { |field, type| [Compiler.column_name(field), unwrap_expr(type)] }
      end

      def unwrap_expr(type)
        case type
        in Type::Application(constructor: Type::Constructor(name: 'Sql.Expr'), args: [inner])
          inner

        else type
        end
      end

      def name_of(type)
        case type
        in Type::AnonymousRecord then 'this record'
        in Type::Application(constructor: Type::Constructor(name:)) then name.split('.').last
        else 'this shape'
        end
      end
    end
  end
end
