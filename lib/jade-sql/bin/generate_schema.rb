require 'jade/lexer'
require 'jade/parsing'
require 'jade/ast'
require 'jade/formatter'
require 'jade/frontend/comment_attacher'

module JadeSql
  module SchemaGenerator
    extend self

    # Array variants are listed first because `\b` would otherwise match
    # the scalar prefix of e.g. `text[]` and map it to "String".
    TYPE_MAP = {
      /\Abigint\[\]/ => "List(Int)",
      /\Ainteger\[\]/ => "List(Int)",
      /\Asmallint\[\]/ => "List(Int)",
      /\Acharacter varying\[\]/ => "List(String)",
      /\Avarchar\[\]/ => "List(String)",
      /\Atext\[\]/ => "List(String)",
      /\Aboolean\[\]/ => "List(Bool)",
      /\Abool\[\]/ => "List(Bool)",
      /\Ajsonb?\[\]/ => "List(Decode.Value)",
      /\Adate\[\]/ => "List(Calendar.Date)",
      /\Atimestamp\[\]/ => "List(Clock.Instant)",
      /\Auuid\[\]/ => "List(Uuid)",
      /\Anumeric\[\]/ => "List(Decimal)",
      /\Adecimal\[\]/ => "List(Decimal)",
      /\Adouble precision\[\]/ => "List(Float)",
      /\Areal\[\]/ => "List(Float)",

      /\Abigint\b/ => "Int",
      /\Ainteger\b/ => "Int",
      /\Asmallint\b/ => "Int",
      /\Anumeric\b/ => "Decimal",
      /\Adecimal\b/ => "Decimal",
      /\Adouble precision\b/ => "Float",
      /\Areal\b/ => "Float",
      /\Acharacter varying\b/ => "String",
      /\Avarchar\b/ => "String",
      /\Acharacter\b/ => "String",
      /\Achar\b/ => "String",
      /\Atext\b/ => "String",
      /\Aboolean\b/ => "Bool",
      /\Abool\b/ => "Bool",
      /\Ajsonb?\b/ => "Decode.Value",
      /\Adate\b/ => "Calendar.Date",
      /\Atimestamp\b/ => "Clock.Instant",
      /\Auuid\b/ => "Uuid",
      /\A(?:big|small)?serial\b/ => "Int",
    }.freeze

    EXTRA_IMPORTS = {
      "Calendar.Date" => "import Calendar",
      "Clock.Instant" => "import Clock",
      "Decode.Value"  => "import Decode",
      "Uuid"          => "import Sql.Uuid exposing(Uuid)",
      "Decimal"       => "import Decimal exposing(Decimal)",
    }.freeze

    # Column names that collide with Jade keywords get a trailing underscore
    # in the struct field; the SQL column reference keeps the real name.
    Table = Data.define(:name, :columns, :pk_columns, :fks, :uniques)
    # `defaulted` is what the database fills in when an INSERT leaves the
    # column out — a DEFAULT clause, an identity or serial sequence. Not the
    # same question as `nullable`: a NOT NULL column with a default is still
    # optional to write.
    Column = Data.define(:name, :jade_type, :nullable, :defaulted)

    def generate(sql, tables: nil, columns: nil, module_name: 'Schema')
      @enums = parse_enums(sql).to_h { [it.name, it] }
      bodies = scan_table_bodies(sql)
      bodies = select_tables(bodies, tables) if tables
      pks = parse_pks(sql)
      fks = parse_fks(sql)
      uniques = parse_uniques(sql)
      defaults = parse_alter_defaults(sql)
      parsed = bodies
        .map { |name, body|
          Table[name, parse_columns(body, name), pks[name] || [], fks[name], uniques[name]]
        }
        .map { |t| t.with(columns: apply_defaults(t.columns, defaults[t.name] || [])) }
        .then { |ts| ts.map { |t| t.with(fks: relations(t, ts)) } }
      parsed = select_columns(parsed, columns) if columns
      format(emit(parsed, module_name))
    end

    # Run jade-fmt over the emitted source so the written schema.jd matches
    # what the formatter would produce — keeps the generator output stable
    # across formatter improvements and avoids spurious diffs when users
    # re-format their tree.
    def format(text)
      source = ::Jade::Source.new(uri: '<schema>', text: text)
      ::Jade::Lexer.tokenize(source)
        .then { ::Jade::Parsing.parse(it, source:) }
        .map { |(ast, comments)| ::Jade::Formatter.format(ast, comments:, source:) }
        .then do
          case it
          in ::Jade::Ok(result) then result.end_with?("\n") ? result : "#{result}\n"
          in ::Jade::Err(_) then text  # parse error — return unformatted; downstream compile will surface it
          end
        end
    end

    private

    # Returns [[name, body], ...] without parsing columns, so the whitelist
    # can be applied before type-mapping — an unsupported type in a table the
    # caller didn't ask for shouldn't abort the whole run.
    def scan_table_bodies(sql)
      sql.scan(/CREATE TABLE (?:\w+\.)?(\w+)\s*\((.*?)\);/m)
    end

    def select_tables(bodies, whitelist)
      missing = whitelist - bodies.map(&:first)
      raise "Unknown table(s): #{missing.join(', ')}" if missing.any?

      bodies.select { |name, _| whitelist.include?(name) }
    end

    # A schema generated for one domain carries only the columns that domain
    # was granted, so a column it wasn't granted is absent from `Cols` and
    # naming it is a type error rather than a review comment.
    def select_columns(tables, whitelist)
      tables.map do |t|
        allowed = whitelist[t.name]
        next t unless allowed

        validate_columns!(t, allowed)

        t.with(columns: t.columns.select { allowed.include?(it.name) })
      end
    end

    def validate_columns!(table, allowed)
      unknown = allowed - table.columns.map(&:name)
      raise "Unknown column(s) on #{table.name}: #{unknown.join(', ')}" if unknown.any?

      (table.pk_columns - allowed).then do
        raise "#{table.name}: primary key #{it.join(', ')} must be selected" if it.any?
      end
    end

    def parse_columns(body, table_name)
      body
        .split("\n")
        .map(&:strip)
        .reject(&:empty?)
        .map { |line| line.sub(/,\s*\z/, '') }
        .reject { |line| line =~ /\A(CONSTRAINT|PRIMARY KEY|UNIQUE|CHECK|FOREIGN KEY)\b/i }
        .map { |line| parse_column(line, table_name) }
    end

    IDENTITY = /\bGENERATED\s+\w+\s+AS\s+IDENTITY\b/i
    SERIAL = /\A(?:big|small)?serial\b/i

    # Modifiers can come in either order (`NOT NULL DEFAULT 0` and
    # `DEFAULT 0 NOT NULL` are both valid), so each is looked for anywhere in
    # the definition rather than anchored to the end.
    def parse_column(line, table_name)
      m = line.match(/\A"?(\w+)"?\s+(.+)\z/m)
      raise "Cannot parse column: #{line.inspect}" unless m

      name, rest = m[1], m[2].strip
      type_part = strip_modifiers(rest)

      jade_type = enum_type(type_part) || TYPE_MAP
        .find { |sql_pat, _| sql_pat.match?(type_part.downcase) }
        &.last

      raise "Unknown SQL type for #{table_name}.#{name}: #{type_part.inspect}" unless jade_type

      Column[
        name,
        jade_type,
        !rest.match?(/\bNOT\s+NULL\b/i),
        rest.match?(/\bDEFAULT\b/i) || rest.match?(IDENTITY) || type_part.match?(SERIAL),
      ]
    end

    def strip_modifiers(rest)
      rest
        .sub(/\s+DEFAULT\s+.+\z/i, '')
        .sub(/\s+GENERATED\s+.+\z/i, '')
        .sub(/\s+COLLATE\s+.+\z/i, '')
        .sub(/\s*\bNOT\s+NULL\b/i, '')
        .strip
    end

    # A Rails structure.sql gives a serial column its default in a separate
    # statement, after the CREATE TABLE:
    #
    #   ALTER TABLE ONLY public.patients
    #     ALTER COLUMN id SET DEFAULT nextval(...);
    ALTER_DEFAULT = /
      ALTER\ TABLE\s+(?:ONLY\s+)?(?:\w+\.)?"?(\w+)"?\s+
      ALTER\ COLUMN\s+"?(\w+)"?\s+SET\ DEFAULT
    /imx

    def parse_alter_defaults(sql)
      sql
        .scan(ALTER_DEFAULT)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
    end

    def apply_defaults(columns, defaulted)
      columns.map { it.defaulted ? it : it.with(defaulted: defaulted.include?(it.name)) }
    end

    Enum = Data.define(:name, :labels)

    # `CREATE TYPE public.visit_status AS ENUM ('scheduled', 'done');`
    def parse_enums(sql)
      sql
        .scan(/CREATE TYPE (?:\w+\.)?(\w+) AS ENUM \(([^)]*)\)/i)
        .map { |name, labels| Enum[name, labels.scan(/'([^']*)'/).flatten] }
    end

    Fk = Data.define(:column, :parent, :parent_column)

    def parse_fks(sql)
      sql
        .scan(/ALTER TABLE (?:ONLY\s+)?(?:\w+\.)?(\w+)\s+ADD CONSTRAINT \w+ FOREIGN KEY \(([^)]+)\) REFERENCES (?:\w+\.)?(\w+)\(([^)]+)\)/i)
        .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(child, col, parent, parent_col), acc|
          acc[child] << Fk[col.strip.delete('"'), parent, parent_col.strip.delete('"')]
        end
    end

    Unique = Data.define(:name, :columns)

    # Both spellings of the same fact: a table-level constraint, which
    # pg_dump writes as an ALTER, and a standalone unique index. A partial
    # index is skipped, since it constrains only the rows its WHERE matches
    # and a conflict target built from it would not be the one it enforces.
    def parse_uniques(sql)
      constraints = sql.scan(
        /ALTER TABLE (?:ONLY\s+)?(?:\w+\.)?(\w+)\s+ADD CONSTRAINT (\w+) UNIQUE \(([^)]+)\)/i,
      )
      indexes = sql
        .scan(/CREATE UNIQUE INDEX (\w+) ON (?:\w+\.)?(\w+) USING \w+ \(([^)]+)\)([^;]*);/i)
        .reject { |(_, _, _, tail)| tail =~ /\bWHERE\b/i }
        .map { |(index, table, cols, _)| [table, index, cols] }

      (constraints + indexes)
        .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(table, name, cols), acc|
          acc[table] << Unique[name, cols.split(',').map { |c| c.strip.delete('"') }]
        end
    end

    def parse_pks(sql)
      sql
        .scan(/ALTER TABLE (?:ONLY\s+)?(?:\w+\.)?(\w+)\s+ADD CONSTRAINT \w+ PRIMARY KEY \(([^)]+)\)/i)
        .to_h { |name, cols| [name, cols.split(',').map { |c| c.strip.delete('"') }] }
    end

    def emit(tables, module_name)
      [
        emit_header(tables, module_name),
        *emit_enums,
        *tables.flat_map { |t| emit_table(t) },
      ].join("\n\n") + "\n"
    end

    Rel = Data.define(:name, :other, :own_column, :other_column, :own_null, :other_null)

    # Both ends of every foreign key, so a join reads the same from either
    # side: `patients.on.phone` and `phones.on.patient` are one constraint.
    # Only relationships whose other end was generated are emitted.
    def relations(t, tables)
      names = tables.map(&:name)

      by_name = tables.to_h { [it.name, it] }
      null = ->(table, col) { table&.columns&.find { it.name == col }&.nullable }

      outgoing = t.fks
        .select { names.include?(it.parent) }
        .map do |fk|
          Rel[
            fk.column.sub(/_id\z/, ""), fk.parent, fk.column, fk.parent_column,
            null.(t, fk.column), null.(by_name[fk.parent], fk.parent_column),
          ]
        end

      incoming = tables
        .flat_map { |other| other.fks.map { [other, it] } }
        .select { |(other, fk)| fk.parent == t.name && other.name != t.name }
        .map do |(other, fk)|
          Rel[
            other.name, other.name, fk.parent_column, fk.column,
            null.(t, fk.parent_column), null.(other, fk.column),
          ]
        end

      dedupe(outgoing + incoming)
    end

    def dedupe(rels)
      rels.each_with_object([]) do |rel, acc|
        taken = acc.map(&:name)
        next acc << rel unless taken.include?(rel.name)

        acc << rel.with(name: "#{rel.name}_#{rel.other_column.sub(/_id\z/, '')}")
      end
    end

    def emit_table(t)
      [
        emit_strict_cols(t),
        emit_left_cols(t),
        *emit_required_cols(t),
        emit_set_cols(t),
        emit_set_cols_fn(t),
        emit_table_alias(t),
        emit_row(t),
        *emit_on(t),
        *emit_on_fns(t),
        emit_table_fn(t),
      ]
        .then { keyed?(t) ? it + [emit_pk_fn(t), emit_pk_values_fn(t)] : it }
        .then { it + t.uniques.map { |u| emit_unique_fn(t, u) } }
        .then { it + [emit_row_projector(t)] }
    end

    def keyed?(t)
      t.pk_columns.any?
    end

    def reserved_cols?(t)
      t.columns.any? { |c| reserved?(c.name) }
    end

    def emit_header(tables, module_name)
      keyed = tables.select { |t| keyed?(t) }

      names = tables
        .flat_map do |t|
          [
            camel(t.name),
            "#{camel(t.name)}Cols",
            "#{camel(t.name)}LeftCols",
            *("Required#{camel(t.name)}Cols" if required_columns(t).any?),
            "#{camel(t.name)}SetCols",
            "#{t.name}_set_cols",
            "#{camel(t.name)}Row(..)",
            *("#{camel(t.name)}On(..)" if t.fks.any?),
            t.name,
          ]
        end
      names += tables.map { |t| "#{t.name}_row" }
      names += keyed.map { |t| "#{t.name}_pk" }
      names += tables.flat_map { |t| t.uniques.map(&:name) }
      names += (@enums || {}).values.map { "#{camel(it.name)}(..)" }
      exposed = names.sort.join(", ")

      joined = tables.select { it.fks.any? }
      bare = tables.select { it.fks.empty? }
      unkeyed = keyed.size < tables.size

      types = [
        "Expr",
        "Col(..)",
        "Table",
        "Selector",
        *("Pk" if keyed.any?),
        *("NoJoins" if bare.any?),
        *("NoKey" if unkeyed),
        *("NoRequiredCols" if tables.any? { required_columns(it).empty? }),
        *("Unique" if tables.any? { it.uniques.any? }),
      ].sort
      fns = [
        "column",
        "table",
        *(%w[eq nullable] if joined.any?),
        *("no_joins" if bare.any?),
        *("pk" if keyed.any?),
        *("unkeyed" if unkeyed),
        *("unique" if tables.any? { it.uniques.any? }),
      ].sort
      sql_import = "import Sql exposing(#{(types + fns).join(', ')})"
      query_import = ["import Sql.Query exposing(Select, field_as, select)"]
      encode_import = keyed.any? ? ["import Decode", "import Encode"] : []
      imports = [sql_import, *query_import, *encode_import, *extra_imports_for(tables)]

      <<~JADE.strip
        module #{module_name} exposing(#{exposed})

        #{imports.join("\n")}
      JADE
    end

    def extra_imports_for(tables)
      tables
        .flat_map { |t| t.columns.map(&:jade_type) }
        .flat_map { |t| [t, t[/\AList\((.*)\)\z/, 1]].compact }
        .uniq
        .filter_map { |jade_type| EXTRA_IMPORTS[jade_type] }
        .uniq
        .sort
    end

    def emit_strict_cols(t)
      fields = t.columns
        .map { |c| "  #{field_name(c.name)}: Expr(#{c.nullable ? "Maybe(#{c.jade_type})" : c.jade_type})" }
        .join(",\n")

      "struct #{camel(t.name)}Cols = {\n#{fields}\n}"
    end

    def emit_left_cols(t)
      fields = t.columns
        .map { |c| "  #{field_name(c.name)}: Expr(Maybe(#{c.jade_type}))" }
        .join(",\n")

      "struct #{camel(t.name)}LeftCols = {\n#{fields}\n}"
    end

    # The columns an insert has to write: NOT NULL, with nothing on the
    # database side to fill them in.
    def required_columns(t)
      t.columns.reject { it.nullable || it.defaulted }
    end

    def emit_required_cols(t)
      required_columns(t).then do |cols|
        next [] if cols.empty?

        cols
          .map { "  #{field_name(it.name)}: Expr(#{it.jade_type})" }
          .join(",\n")
          .then { ["struct Required#{camel(t.name)}Cols = {\n#{it}\n}"] }
      end
    end

    def required_type(t)
      required_columns(t).any? ? "Required#{camel(t.name)}Cols" : 'NoRequiredCols'
    end

    # The table's own type, with every argument filled in. Nothing else can
    # shorten `Table(c, m, k, o, r, s)`: an alias has to bind every variable its
    # body names, so only a fully applied one saves anything.
    # The left of a `SET` is a column name, not an expression, so the fields
    # are `Col` rather than `Expr` and nothing recovers a name from rendered
    # SQL.
    def emit_set_cols(t)
      t.columns
        .map { "  #{field_name(it.name)}: Col(#{it.jade_type})" }
        .join(",\n")
        .then { "struct #{camel(t.name)}SetCols = {\n#{it}\n}" }
    end

    def emit_set_cols_fn(t)
      t.columns
        .map { "    Col(#{it.name.inspect})" }
        .join(",\n")
        .then do
          "def #{t.name}_set_cols -> #{camel(t.name)}SetCols\n" \
            "  #{camel(t.name)}SetCols(\n#{it},\n  )\nend"
        end
    end

    def emit_table_alias(t)
      [
        "#{camel(t.name)}Cols",
        "#{camel(t.name)}LeftCols",
        key_type(t),
        on_type(t),
        required_type(t),
        "#{camel(t.name)}SetCols",
      ].join(', ').then { "type alias #{camel(t.name)} = Table(#{it})" }
    end

    def emit_row(t)
      fields = t.columns
        .map { |c| "  #{field_name(c.name)}: #{c.nullable ? "Maybe(#{c.jade_type})" : c.jade_type}" }
        .join(",\n")

      "struct #{camel(t.name)}Row = {\n#{fields}\n}"
    end

    # A column whose name is a jade keyword cannot be a field, so it gains a
    # trailing underscore. `JadeSql::Compiler.column_name` is the inverse, and
    # both read the lexer rather than a list of their own.
    def reserved?(name) = Jade::Lexer::KEYWORDS.include?(name)

    def field_name(name)
      reserved?(name) ? "#{name}_" : name
    end

    def emit_table_fn(t)
      strict_fields = t.columns.map { |c| "column(a, #{c.name.inspect})" }.join(", ")
      maybe_fields = t.columns.map { |c| "column(a, #{c.name.inspect})" }.join(", ")

      <<~JADE.strip
        def #{t.name} -> #{camel(t.name)}
          table(
            #{t.name.inspect},
            #{t.name.inspect},
            (a) -> { #{camel(t.name)}Cols(#{strict_fields}) },
            (a) -> { #{camel(t.name)}LeftCols(#{maybe_fields}) },
            #{t.name}_set_cols,
            #{keyed?(t) ? "#{t.name}_pk" : "unkeyed"},
            #{emit_on_value(t)},
          )
        end
      JADE
    end

    def key_columns(t)
      t.columns.select { t.pk_columns.include?(it.name) }
        .sort_by { t.pk_columns.index(it.name) }
    end

    def key_type(t)
      return "NoKey" unless keyed?(t)

      key_columns(t)
        .map(&:jade_type)
        .then { it.one? ? it.first : "(#{it.join(', ')})" }
    end

    def emit_on(t)
      return nil if t.fks.empty?

      fields = t.fks
        .map { "  #{it.name}: #{camel(t.name)}Cols -> (#{camel(it.other)}Cols -> Expr(Bool))" }
        .join(",\n")

      "struct #{camel(t.name)}On = {\n#{fields}\n}"
    end

    def on_type(t)
      t.fks.empty? ? "NoJoins" : "#{camel(t.name)}On"
    end

    def emit_on_value(t)
      return "no_joins" if t.fks.empty?

      t.fks
        .map { on_fn_name(t, it) }
        .join(", ")
        .then { "#{camel(t.name)}On(#{it})" }
    end

    # A nullable foreign key column is `Expr(Maybe(a))` while the key it
    # points at is `Expr(a)`, so whichever side is not nullable is lifted.
    def side(var, column, mine, theirs)
      ref = "#{var}.#{field_name(column)}"

      !mine && theirs ? "#{ref} |> nullable" : ref
    end

    def on_fn_name(t, rel)
      "#{t.name}_on_#{rel.name}"
    end

    # Named rather than inlined in the constructor for the same reason the key
    # spread is: inference does not reach a lambda passed to a constructor, so
    # `a.phone_id` there infers an open record instead of the column struct.
    def emit_on_fns(t)
      t.fks.map do |rel|
        <<~JADE.strip
          def #{on_fn_name(t, rel)}(a: #{camel(t.name)}Cols) -> #{camel(rel.other)}Cols -> Expr(Bool)
            (b) -> {
              eq(#{side("a", rel.own_column, rel.own_null, rel.other_null)}, #{side("b", rel.other_column, rel.other_null, rel.own_null)})
            }
          end
        JADE
      end
    end

    # The index name is what Postgres reports in a violation, so naming it
    # here is what lets a caller route the error without matching a string.
    def emit_unique_fn(t, u)
      cols = u.columns.map { it.inspect }.join(", ")

      <<~JADE.strip
        def #{u.name} -> Unique(#{camel(t.name)}Cols)
          unique(#{u.name.inspect}, [#{cols}])
        end
      JADE
    end

    def emit_pk_fn(t)
      cols = key_columns(t).map { it.name.inspect }.join(", ")

      <<~JADE.strip
        def #{t.name}_pk -> Pk(#{camel(t.name)}Cols, #{key_type(t)})
          pk([#{cols}], #{t.name}_pk_values)
        end
      JADE
    end

    # A composite key arrives as a tuple and has to spread across its columns
    # in the order the DDL declares them, never the order a caller guesses.
    # Named rather than a lambda so its parameter carries an annotation:
    # inference does not reach a lambda passed to `Pk`, and destructuring a
    # value of unknown type is a non-exhaustive match.
    def emit_pk_values_fn(t)
      names = key_columns(t).each_index.map { |i| "v#{i}" }
      encoded = names.map { "Encode.encode(#{it})" }.join(", ")

      body = names.one? ?
        "  [Encode.encode(v)]" :
        "  (#{names.join(', ')}) = v\n\n  [#{encoded}]"

      <<~JADE.strip
        def #{t.name}_pk_values(v: #{key_type(t)}) -> List(Decode.Value)
        #{body}
        end
      JADE
    end

    # A row projector that aliases every column to its (possibly renamed)
    # field name, so a reserved-word column like `type` round-trips through
    # decode: `SELECT alias.type AS type_`. Emitted only for tables that have
    # a renamed column. Composes in a bind-chain:
    #   c <- from(t)
    #   t_row(c) |> where(...)
    def emit_row_projector(t)
      klass = camel(t.name)
      holes = t.columns.map { "_" }.join(", ")
      projections = t.columns
        .map { |c| "    |> field_as(c.#{field_name(c.name)}, #{field_name(c.name).inspect})" }
        .join("\n")

      <<~JADE.strip
        def #{t.name}_row(c: #{klass}Cols) -> Select(#{klass}Row)
          select(#{klass}Row(#{holes}))
        #{projections}
        end
      JADE
    end

    # A column typed by a CREATE TYPE enum, with or without its schema prefix.
    def enum_type(type_part)
      type_part
        .sub(/\A\w+\./, "")
        .then { @enums&.key?(it) ? camel(it) : nil }
    end

    def emit_enums
      (@enums || {})
        .values
        .map { |e| "type #{camel(e.name)}\n  = #{e.labels.map { camel(it) }.join("\n  | ")}" }
    end

    def camel(snake)
      snake.split('_').map(&:capitalize).join
    end
  end
end

if __FILE__ == $0
  if ARGV.empty?
    warn "Usage: ruby #{$0} <schema.sql>"
    warn "       TABLES=a,b  whitelist of tables (default: all)"
    warn "       MODULE=Name override module name (default: Schema)"
    exit 1
  end

  tables = ENV['TABLES']&.split(',')&.map(&:strip)&.reject(&:empty?)
  module_name = ENV['MODULE'] || 'Schema'

  puts JadeSql::SchemaGenerator.generate(File.read(ARGV[0]), tables: tables, module_name: module_name)
end
