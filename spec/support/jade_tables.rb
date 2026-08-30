# Jade source for a table: its column struct, the nullable view of that struct
# an outer join produces, and the `table` function tying them together.
#
#   jade_table('patients', { id: 'Int', name: 'String', balance: 'Maybe(Int)' })
#
# The column map gives each column's type as it appears in a row; the nullable
# view is derived from it. `key: 'NoKey'` emits an unkeyed table, and `on:`
# names an `on` record instead of `no_joins`.
module JadeTables
  def jade_table(name, columns, key: 'Int', alias_: nil, on: nil)
    klass = camel(name)
    alias_ ||= name

    [
      cols_struct("#{klass}Cols", columns) { |t| "Expr(#{t})" },
      cols_struct("Maybe#{klass}Cols", columns) { |t| "Expr(#{maybe(t)})" },
      table_fn(name, klass, columns, key, alias_, on),
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

  def table_fn(name, klass, columns, key, alias_, on)
    reads = columns.keys.map { "column(a, #{it.to_s.inspect})" }.join(', ')

    <<~JADE.strip
      def #{name} -> Table(#{klass}Cols, Maybe#{klass}Cols, #{key}, #{on || 'NoJoins'})
        table(
          #{name.inspect},
          #{alias_.inspect},
          (a) -> { #{klass}Cols(#{reads}) },
          (a) -> { Maybe#{klass}Cols(#{reads}) },
          #{key == 'NoKey' ? 'unkeyed' : "pk([\"id\"], (v) -> { [Encode.encode(v)] })"},
          #{on ? "#{name}_on" : 'no_joins'},
        )
      end
    JADE
  end

  def maybe(type) = type.start_with?('Maybe(') ? type : "Maybe(#{type})"

  def camel(name) = name.split('_').map(&:capitalize).join
end

RSpec.configure { it.include JadeTables }
