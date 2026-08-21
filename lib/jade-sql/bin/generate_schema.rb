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
    RESERVED = %w[
      type def module import exposing struct interface implements uses
      case in if then else end with
    ].freeze

    Table = Data.define(:name, :columns, :pk_columns)
    Column = Data.define(:name, :jade_type, :nullable)

    def generate(sql, tables: nil, columns: nil, module_name: 'Schema')
      @enums = parse_enums(sql).to_h { [it.name, it] }
      bodies = scan_table_bodies(sql)
      bodies = select_tables(bodies, tables) if tables
      pks = parse_pks(sql)
      parsed = bodies.map { |name, body| Table[name, parse_columns(body, name), pks[name] || []] }
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

    def parse_column(line, table_name)
      m = line.match(/\A"?(\w+)"?\s+(.+?)(\s+NOT\s+NULL)?\s*\z/i)
      raise "Cannot parse column: #{line.inspect}" unless m

      name, type_part, not_null = m[1], m[2].strip, !m[3].nil?

      # Strip trailing modifiers we don't care about (DEFAULT ..., COLLATE ...).
      type_part = type_part.sub(/\s+DEFAULT\s+.+\z/i, '').sub(/\s+COLLATE\s+.+\z/i, '').strip

      jade_type = enum_type(type_part) || TYPE_MAP
        .find { |sql_pat, _| sql_pat.match?(type_part.downcase) }
        &.last

      raise "Unknown SQL type for #{table_name}.#{name}: #{type_part.inspect}" unless jade_type

      Column[name, jade_type, !not_null]
    end

    Enum = Data.define(:name, :labels)

    # `CREATE TYPE public.visit_status AS ENUM ('scheduled', 'done');`
    def parse_enums(sql)
      sql
        .scan(/CREATE TYPE (?:\w+\.)?(\w+) AS ENUM \(([^)]*)\)/i)
        .map { |name, labels| Enum[name, labels.scan(/'([^']*)'/).flatten] }
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

    def emit_table(t)
      [emit_strict_cols(t), emit_maybe_cols(t), emit_row(t), emit_table_fn(t)]
        .then { keyed?(t) ? it + [emit_pk_fn(t), emit_pk_values_fn(t)] : it }
        .then { reserved_cols?(t) ? it + [emit_row_projector(t)] : it }
    end

    def keyed?(t)
      t.pk_columns.any?
    end

    def reserved_cols?(t)
      t.columns.any? { |c| RESERVED.include?(c.name) }
    end

    def emit_header(tables, module_name)
      projectored = tables.select { |t| reserved_cols?(t) }
      keyed = tables.select { |t| keyed?(t) }

      names = tables
        .flat_map { |t| ["#{camel(t.name)}Cols", "Maybe#{camel(t.name)}Cols", "#{camel(t.name)}Row(..)", t.name] }
      names += projectored.map { |t| "#{t.name}_row" }
      names += keyed.map { |t| "#{t.name}_pk" }
      names += (@enums || {}).values.map { "#{camel(it.name)}(..)" }
      exposed = names.sort.join(", ")

      unkeyed = keyed.size < tables.size
      types = [
        "Expr", "Table",
        *("Selector" if projectored.any?),
        *("Pk(..)" if keyed.any?),
        *("NoKey" if unkeyed),
      ].sort
      fns = ["column", "table", *("unkeyed" if unkeyed)].sort
      sql_import = "import Sql exposing(#{(types + fns).join(', ')})"
      query_import = projectored.any? ? ["import Sql.Query exposing(Q, field_as, select)"] : []
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

    def emit_maybe_cols(t)
      fields = t.columns
        .map { |c| "  #{field_name(c.name)}: Expr(Maybe(#{c.jade_type}))" }
        .join(",\n")

      "struct Maybe#{camel(t.name)}Cols = {\n#{fields}\n}"
    end

    def emit_row(t)
      fields = t.columns
        .map { |c| "  #{field_name(c.name)}: #{c.nullable ? "Maybe(#{c.jade_type})" : c.jade_type}" }
        .join(",\n")

      "struct #{camel(t.name)}Row = {\n#{fields}\n}"
    end

    def field_name(name)
      RESERVED.include?(name) ? "#{name}_" : name
    end

    def emit_table_fn(t)
      strict_fields = t.columns.map { |c| "column(a, #{c.name.inspect})" }.join(", ")
      maybe_fields = t.columns.map { |c| "column(a, #{c.name.inspect})" }.join(", ")

      <<~JADE.strip
        def #{t.name} -> Table(#{camel(t.name)}Cols, Maybe#{camel(t.name)}Cols, #{key_type(t)})
          table(
            #{t.name.inspect},
            #{t.name.inspect},
            (a) -> { #{camel(t.name)}Cols(#{strict_fields}) },
            (a) -> { Maybe#{camel(t.name)}Cols(#{maybe_fields}) },
            #{keyed?(t) ? "#{t.name}_pk" : "unkeyed"},
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

    def emit_pk_fn(t)
      cols = key_columns(t).map { it.name.inspect }.join(", ")

      <<~JADE.strip
        def #{t.name}_pk -> Pk(#{camel(t.name)}Cols, #{key_type(t)})
          Pk([#{cols}], #{t.name}_pk_values)
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
        def #{t.name}_row(c: #{klass}Cols) -> Q(Selector(#{klass}Row))
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
