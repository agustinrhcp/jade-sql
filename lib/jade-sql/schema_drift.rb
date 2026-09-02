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

    def between(generated, existing)
      tables = table_names(generated) | table_names(existing)

      [definitions(generated), definitions(existing)]
        .then { |from_db, on_disk| report(from_db, on_disk, tables) }
    end

    private

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

    def table_names(source)
      source.scan(/^def (\w+) ->\s*Table\(/).flatten
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
