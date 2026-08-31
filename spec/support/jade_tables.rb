# Jade source for a table: its column struct, the nullable view of that struct
# an outer join produces, and the `table` function tying them together.
#
#   jade_table('patients', { id: 'Int', name: 'String', balance: 'Maybe(Int)' })
#
# The column map gives each column's type as it appears in a row; the nullable
# view is derived from it. `key:` is the key's type, `NoKey` for a table with
# no primary key. `pk:` and `joins:` take the expressions themselves, for the
# tables the defaults do not fit — a composite key, an `on` record.
#
# `required:` names the columns an insert has to write, defaulting to the
# columns that are neither nullable nor `id`.
module JadeTables
  DEFAULT_PK = 'pk(["id"], (v) -> { [Encode.encode(v)] })'.freeze

  def jade_table(name, columns, key: 'Int', alias_: nil, pk: nil, joins: 'no_joins', required: nil)
    klass = camel(name)
    pk ||= key == 'NoKey' ? 'unkeyed' : DEFAULT_PK
    required ||= columns.keys.reject { it.to_s == 'id' || columns[it].start_with?('Maybe(') }

    [
      cols_struct("#{klass}Cols", columns) { |t| "Expr(#{t})" },
      cols_struct("Maybe#{klass}Cols", columns) { |t| "Expr(#{maybe(t)})" },
      *(cols_struct("Required#{klass}Cols", columns.slice(*required)) { |t| "Expr(#{t})" } if required.any?),
      table_fn(name, klass, columns, key, alias_ || name, pk, joins, required),
    ].join("\n\n\n")
  end

  # The `Pk` as a named function, for a table whose fixture refers to it.
  def jade_pk(name, key_columns = ['id'], key: 'Int')
    <<~JADE.strip
      def #{name}_pk -> Pk(#{camel(name)}Cols, #{key})
        pk([#{key_columns.map(&:inspect).join(', ')}], (v) -> { [Encode.encode(v)] })
      end
    JADE
  end

  private

  # One field fits on a line, which is what the formatter would do to it.
  def cols_struct(struct_name, columns)
    fields = columns.map { |field, type| "#{field}: #{yield(type)}" }

    if fields.one?
      "struct #{struct_name} = { #{fields.first} }"
    else
      "struct #{struct_name} = {\n#{fields.map { "  #{it}" }.join(",\n")}\n}"
    end
  end

  def table_fn(name, klass, columns, key, alias_, pk, joins, required)
    reads = columns.keys.map { "column(a, #{column_name(it).inspect})" }

    <<~JADE.strip
      def #{name} -> #{signature(klass, key, joins, required)}
        table(
          #{name.inspect},
          #{alias_.inspect},
          (a) -> { #{constructor("#{klass}Cols", reads)} },
          (a) -> { #{constructor("Maybe#{klass}Cols", reads)} },
          #{pk},
          #{joins},
        )
      end
    JADE
  end

  # The formatter leaves a type annotation on one line however long it runs.
  def signature(klass, key, joins, required)
    [
      "#{klass}Cols",
      "Maybe#{klass}Cols",
      key,
      joins_type(joins),
      required.any? ? "Required#{klass}Cols" : 'NoRequiredCols',
    ].join(', ').then { "Table(#{it})" }
  end

  # The formatter breaks a constructor call once it outgrows the line.
  def constructor(klass, reads)
    one_line = "#{klass}(#{reads.join(', ')})"

    if one_line.length <= 60
      one_line
    else
      "#{klass}(\n#{reads.map { "      #{it}," }.join("\n")}\n    )"
    end
  end

  # A column whose name is a jade keyword gains a trailing underscore to be a
  # field, the same escape `generate_schema` applies.
  def column_name(field)
    field.to_s.then { Jade::Lexer::KEYWORDS.include?(it.chomp('_')) ? it.chomp('_') : it }
  end

  def joins_type(joins) = joins == 'no_joins' ? 'NoJoins' : joins[/\A\w+/]

  def maybe(type) = type.start_with?('Maybe(') ? type : "Maybe(#{type})"

  def camel(name) = name.split('_').map(&:capitalize).join
end

RSpec.configure { it.include JadeTables }
