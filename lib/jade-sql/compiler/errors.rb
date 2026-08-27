module JadeSql
  module Compiler
    module Errors
      class UnknownColumn < Jade::Error
        def initialize(entry, span, struct:, field:, table:)
          @struct = struct
          @field = field
          @table = table
          super(entry:, span:)
        end

        def message
          "#{@struct}.#{@field} has no column on #{@table}"
        end

        def label
          "no column `#{@field}`"
        end
      end

      class ColumnTypeMismatch < Jade::Error
        def initialize(entry, span, struct:, field:, table:, column:, expected:, actual:)
          @struct = struct
          @field = field
          @table = table
          @column = column
          @expected = expected
          @actual = actual
          super(entry:, span:)
        end

        def message
          "#{@table}.#{@column} is #{@expected}, " \
            "but #{@struct}.#{@field} is #{@actual}"
        end

        def label
          "column is #{@expected}, field is #{@actual}"
        end
      end
    end
  end
end
