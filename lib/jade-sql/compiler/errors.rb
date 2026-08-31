module JadeSql
  module Compiler
    module Errors
      class UnknownColumn < Jade::Error
        def initialize(entry, span, struct:, field:, table:, columns:)
          @struct = struct
          @field = field
          @table = table
          @columns = columns
          super(entry:, span:)
        end

        def message
          "#{@struct}.#{@field} has no column on #{@table}"
        end

        def label
          "no column `#{@field}`"
        end

        def queried_name = @field.to_s

        def candidates = @columns
      end

      class MissingColumns < Jade::Error
        STAMPS = %w[created_at updated_at].freeze

        def initialize(entry, span, struct:, table:, missing:)
          @struct = struct
          @table = table
          @missing = missing
          super(entry:, span:)
        end

        def message
          "#{@struct} does not write #{list(@missing)}, " \
            "which #{@table} requires"
        end

        def label
          "missing #{list(@missing)}"
        end

        def notes
          return [] unless (@missing - STAMPS).empty?

          [Jade::Diagnostics::Annotation[:help, 'pipe the value through `stamped`']]
        end

        private

        def list(names)
          names.map { "`#{it}`" }.then do |quoted|
            quoted.length == 1 ? quoted.first : "#{quoted[..-2].join(', ')} and #{quoted.last}"
          end
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
