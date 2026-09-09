module JadeSql
  # What a checked-in schema.jd says against what the database says now.
  #
  # The generator reads `structure.sql` and nothing else, so a schema that
  # was not regenerated after a migration describes a database that no
  # longer exists, and every type built on it is wrong in a way the
  # compiler cannot see.
  module SchemaDrift
    extend self

    Report = Data.define(:added, :removed, :changed) do
      def any?
        [added, removed, changed].any?(&:any?)
      end

      def to_s
        [
          'schema.jd no longer matches the database:',
          '',
          *line('in the database, missing here', added),
          *line('here, gone from the database', removed),
          *line('different', changed),
          '',
          'Regenerate it with `jade-sql schema`.',
        ].join("\n")
      end

      private

      def line(label, names)
        names.empty? ? [] : ["  #{label}: #{names.join(', ')}"]
      end
    end

    # Both sides are module name to source, since a schema is a module per
    # enum plus the root one. A module the database no longer calls for is
    # itself a difference, so the comparison is per module rather than over
    # everything concatenated.
    def between(generated, existing)
      names = generated.keys | existing.keys
      tables = names
        .flat_map { table_names(generated[it].to_s) + table_names(existing[it].to_s) }
        .uniq

      names
        .map { module_report(generated[it], existing[it], it, tables) }
        .then { |reports| merge(reports) }
    end

    private

    # A module present on one side only is reported whole, under its own name.
    # Otherwise the definitions inside it are compared and grouped by table.
    def module_report(from_db, on_disk, name, tables)
      case [from_db, on_disk]
      in [String, nil] then Report[[name], [], []]
      in [nil, String] then Report[[], [name], []]
      in [String, String] then report(definitions(from_db), definitions(on_disk), tables)
      end
    end

    def merge(reports)
      Report[
        reports.flat_map(&:added).uniq.sort,
        reports.flat_map(&:removed).uniq.sort,
        reports.flat_map(&:changed).uniq.sort,
      ]
    end

    def report(from_db, on_disk, tables)
      Report[
        grouped(from_db.keys - on_disk.keys, tables),
        grouped(on_disk.keys - from_db.keys, tables),
        grouped((from_db.keys & on_disk.keys).select { from_db[it] != on_disk[it] }, tables),
      ]
    end

    # One table produces eight definitions, and a report naming all eight
    # says less than one naming the table.
    def grouped(names, tables)
      names.map { table_for(it, tables) || it }.uniq.sort
    end

    def table_for(name, tables)
      name
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
        .then { |snake| tables.select { snake.include?(it) } }
        .max_by(&:length)
    end

    # A table function returns the per-table alias rather than `Table(...)`
    # itself, so the aliases are read first and the functions matched against
    # them. Grouping every definition under its table is the whole point of
    # the report: one migration renames a column and a dozen structs change.
    def table_names(source)
      source
        .scan(/^type alias (\w+) = Table\(/)
        .flatten
        .then { |aliases| source.scan(/^def (\w+) -> (#{Regexp.union(aliases)})$/) }
        .map(&:first)
    end

    # Split on what a definition starts with, so the report names the table
    # or type that moved rather than a line number.
    DEFINITION = /^(?:def|struct|type)\s+([\w.?!]+)/

    def definitions(source)
      source
        .split(/^(?=(?:def|struct|type)\s)/)
        .filter_map { |chunk| chunk[DEFINITION, 1]&.then { |name| [name, chunk.strip] } }
        .to_h
    end
  end
end
