require 'date'
require 'bigdecimal'
require 'jade/tasks'

# Opt-in runtime: requires ActiveRecord. The Jade-side Sql.Run module
# declares ports against this. Loaded only when the user explicitly does
# `require 'jade-sql/runtime'`.
module JadeSql
  module Runtime
    extend Jade::Port

    task :port_execute_count do |t, sql, params|
      conn = ::ActiveRecord::Base.connection
      t.ok(conn.exec_update(adapt_sql(fill_now(sql), conn), "Jade", typed_params(params, conn)))
    rescue ::ActiveRecord::RecordNotUnique => e
      t.err(JadeSql::SqlErrors.conflict(constraint_name(e)))
    rescue ::ActiveRecord::StatementInvalid => e
      t.err(JadeSql::SqlErrors.db_error(e.message))
    end

    task :port_execute_one do |t, sql, params|
      conn = ::ActiveRecord::Base.connection
      rows = conn.exec_query(adapt_sql(fill_now(sql), conn), "Jade", typed_params(params, conn)).to_a
      case rows.length
      when 0 then t.err(JadeSql::SqlErrors.not_found)
      when 1 then t.ok(coerce_row(rows.first))
      else        t.err(JadeSql::SqlErrors.not_unique)
      end
    rescue ::ActiveRecord::RecordNotUnique => e
      t.err(JadeSql::SqlErrors.conflict(constraint_name(e)))
    rescue ::ActiveRecord::StatementInvalid => e
      t.err(JadeSql::SqlErrors.db_error(e.message))
    end

    task :port_execute_many do |t, sql, params|
      conn = ::ActiveRecord::Base.connection
      rows = conn.exec_query(adapt_sql(fill_now(sql), conn), "Jade", typed_params(params, conn)).to_a
      t.ok(rows.map { |row| coerce_row(row) })
    rescue ::ActiveRecord::RecordNotUnique => e
      t.err(JadeSql::SqlErrors.conflict(constraint_name(e)))
    rescue ::ActiveRecord::StatementInvalid => e
      t.err(JadeSql::SqlErrors.db_error(e.message))
    end

    # Transaction control on the shared connection. The execute/fetch ports
    # above use the same `ActiveRecord::Base.connection`, so anything they
    # run between begin and commit/rollback is part of this transaction.
    # These bypass AR's transaction manager (no savepoints), so they don't
    # nest — see `Sql.transaction`. Rollback is best-effort: it swallows
    # adapter errors so the original failure is the one that propagates.
    task :port_begin do |t|
      ::ActiveRecord::Base.connection.begin_db_transaction
      t.ok(true)
    rescue ::ActiveRecord::StatementInvalid => e
      t.err(JadeSql::SqlErrors.db_error(e.message))
    end

    task :port_commit do |t|
      ::ActiveRecord::Base.connection.commit_db_transaction
      t.ok(true)
    rescue ::ActiveRecord::StatementInvalid => e
      t.err(JadeSql::SqlErrors.db_error(e.message))
    end

    task :port_rollback do |t|
      ::ActiveRecord::Base.connection.rollback_db_transaction
      t.ok(true)
    rescue ::ActiveRecord::StatementInvalid
      t.ok(true)
    end

    # AR's PG adapter returns ::Date / ::Time for date/timestamp columns;
    # Calendar.Date / Clock.Instant decoders expect ISO strings. Coerce
    # at the boundary so callers don't sprinkle text_cast in every SELECT.
    #
    # text[] / int[] / etc. arrive as Postgres array literals (`{a,b,c}`)
    # when AR's exec_query path doesn't run the OID typecast. Parse them
    # back to Ruby Arrays so `Decode.list(...)` works the same as for any
    # other List(a) column.
    #
    # numeric/decimal columns come back as ::BigDecimal; the schema generator
    # maps them to jade's stdlib Decimal, whose decoder reads the exact
    # "<coefficient>e<exponent>" wire form. Float would lose precision, so don't.
    # Most rows have nothing to convert — Integers, plain Strings and nils
    # all come back as themselves — so the copy only happens once a value
    # actually changes, and each value is still only looked at once.
    def self.coerce_row(row)
      out = nil

      row.each_pair do |k, v|
        coerced = coerce_value(v)
        (out ||= row.dup)[k] = coerced unless coerced.equal?(v)
      end

      out || row
    end

    def self.coerce_value(v)
      case v
      when ::Date             then v.iso8601
      when ::Time, ::DateTime then v.iso8601
      when ::BigDecimal       then decimal_wire(v)
      when ::String
        pg_array_literal?(v) ? parse_pg_array(v) : v
      else v
      end
    end

    # ::BigDecimal -> "<coefficient>e<exponent>" with value = coeff * 10^exp,
    # exactly (BigDecimal#split gives sign, significant digits, and a base-10
    # exponent). Matches the wire form jade's stdlib Decimal decoder parses.
    #
    # 'NaN'/'Infinity'::numeric are legal Postgres values that Decimal can't
    # represent; fail loudly rather than silently decode them as 0.
    def self.decimal_wire(v)
      raise ArgumentError, "non-finite numeric: #{v}" unless v.finite?

      sign, digits, _base, exp = v.split
      coefficient = sign * digits.to_i
      exponent = exp - digits.length
      "#{coefficient}e#{exponent}"
    end

    # PG arrays render as `{}`, `{a,b,c}`, `{"a,b","c"}`, with NULL as
    # bare `NULL`. Quoted elements escape `"` and `\` with backslashes.
    # The JSON-object guard rejects `{"key":...}` shapes — they share the
    # outer braces but should reach Decode.Value as plain strings (or as
    # Hash if AR already typecast the column).
    PG_ARRAY_LITERAL = /\A\{.*\}\z/m
    JSON_OBJECT_HEAD = /\A\{\s*"[^"]*"\s*:/m

    def self.pg_array_literal?(s)
      s.match?(PG_ARRAY_LITERAL) && !s.match?(JSON_OBJECT_HEAD)
    end

    def self.parse_pg_array(s)
      inner = s[1..-2]
      return [] if inner.empty?

      elements = []
      buffer = String.new
      in_quotes = false
      i = 0
      while i < inner.length
        c = inner[i]
        if in_quotes
          if c == '\\' && i + 1 < inner.length
            buffer << inner[i + 1]
            i += 2
            next
          elsif c == '"'
            in_quotes = false
          else
            buffer << c
          end
        else
          if c == '"'
            in_quotes = true
          elsif c == ','
            elements << decode_element(buffer)
            buffer = String.new
          else
            buffer << c
          end
        end
        i += 1
      end
      elements << decode_element(buffer)
      elements
    end

    def self.decode_element(raw)
      raw == "NULL" ? nil : raw
    end

    # The constraint/index name behind a RecordNotUnique, so callers can route
    # by which unique index was violated. PG reports it in the error's
    # diagnostics; other adapters (or a missing name) fall back to "".
    def self.constraint_name(error)
      cause = error.cause
      return "" unless defined?(::PG::Result) && cause.respond_to?(:result) && cause.result

      cause.result.error_field(::PG::Result::PG_DIAG_CONSTRAINT_NAME) || ""
    rescue StandardError
      ""
    end

    # Sql.Mutation.timestamped emits "$JADE_SQL_NOW$" where created_at /
    # updated_at go. Swap it for one UTC timestamp literal per statement,
    # computed here — the app clock, so it moves with travel_to/Timecop
    # (unlike DB now()). The token lives in SQL we generate, never in a
    # bound value, so it can't collide with user data.
    NOW_TOKEN = "$JADE_SQL_NOW$"

    def self.fill_now(sql)
      return sql unless sql.include?(NOW_TOKEN)

      stamp = "'#{::Time.now.utc.strftime('%Y-%m-%d %H:%M:%S.%6N+00')}'"
      sql.gsub(NOW_TOKEN) { stamp }
    end

    # Sql renders `?` placeholders uniformly. AR's exec_query/exec_update
    # path on the PG adapter expects `$1, $2, …` — there is no `?`-to-`$n`
    # rewrite at that layer. SQLite and MySQL accept `?` directly, so this
    # is a no-op there.
    #
    # The alternation matches a whole quoted span first (single-quoted
    # string with `''` escapes, or double-quoted identifier with `""`
    # escapes), so a literal `?` inside one is left alone — only bare `?`
    # outside quotes becomes a placeholder. Dollar-quoted bodies aren't
    # handled (uncommon in app SQL).
    QUOTED_OR_PLACEHOLDER = /'(?:[^']|'')*'|"(?:[^"]|"")*"|\?/

    def self.adapt_sql(sql, conn)
      return sql unless conn.adapter_name =~ /postgres/i

      n = 0
      sql.gsub(QUOTED_OR_PLACEHOLDER) { |m| m == "?" ? "$#{n += 1}" : m }
    end

    # AR's exec_query raw path can't bind a Ruby Array — pg's OID type
    # cast isn't applied to bare values. Wrap arrays in QueryAttribute
    # with a PG OID::Array so the binding picks the right wire format.
    # Element type sniffs the first non-nil entry; falls back to text.
    def self.typed_params(params, conn)
      return params unless conn.adapter_name =~ /postgres/i

      params.map { |p| typed_param(p) }
    end

    def self.typed_param(value)
      case value
      when ::Array
        ::ActiveRecord::Relation::QueryAttribute.new(nil, value, array_type_for(value))
      else
        value
      end
    end

    def self.array_type_for(elements)
      sample = elements.find { |e| !e.nil? }
      element_type =
        case sample
        when ::Integer            then ::ActiveRecord::Type::Integer.new
        when ::Float              then ::ActiveRecord::Type::Float.new
        when true, false          then ::ActiveRecord::Type::Boolean.new
        else                           ::ActiveRecord::Type::String.new
        end

      ::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(element_type)
    end
  end
end
