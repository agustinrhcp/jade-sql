require 'jade-sql/bin/generate_schema'
require 'jade-sql/schema_drift'

namespace :jade do
  desc "Generate schema.jd from db/structure.sql (INPUT, OUTPUT, TABLES, COLUMNS, MODULE)"
  task :schema do
    input       = ENV['INPUT']  || 'db/structure.sql'
    output      = ENV['OUTPUT'] || 'app/jade/schema.jd'
    tables      = ENV['TABLES']&.split(',')&.map(&:strip)&.reject(&:empty?)
    columns     = parse_columns_env(ENV['COLUMNS'])
    module_name = ENV['MODULE'] || 'Schema'

    FileUtils.mkdir_p(File.dirname(output))
    File.write(
      output,
      JadeSql::SchemaGenerator.generate(
        File.read(input), tables:, columns:, module_name:
      ),
    )

    puts "wrote #{output}"
  end

  namespace :schema do
    desc "Fail if schema.jd no longer matches db/structure.sql (INPUT, OUTPUT, TABLES, COLUMNS, MODULE)"
    task :check do
      input       = ENV['INPUT']  || 'db/structure.sql'
      output      = ENV['OUTPUT'] || 'app/jade/schema.jd'
      tables      = ENV['TABLES']&.split(',')&.map(&:strip)&.reject(&:empty?)
      columns     = parse_columns_env(ENV['COLUMNS'])
      module_name = ENV['MODULE'] || 'Schema'

      abort "#{output} does not exist. Generate it with `rake jade:schema`." unless File.exist?(output)

      JadeSql::SchemaGenerator
        .generate(File.read(input), tables:, columns:, module_name:)
        .then { JadeSql::SchemaDrift.between(it, File.read(output)) }
        .then { it.any? ? abort(it.to_s) : puts("#{output} matches #{input}.") }
    end
  end

  # COLUMNS="patients:id,age;visits:id,seen_on" — tables separated by `;`,
  # their columns by `,`. A table left out keeps all of its columns.
  def parse_columns_env(raw)
    return nil unless raw

    raw
      .split(';')
      .reject { it.strip.empty? }
      .to_h do
        table, cols = it.split(':', 2)
        raise "COLUMNS entry #{it.inspect} needs the form table:col,col" if cols.nil?

        [table.strip, cols.split(',').map(&:strip).reject(&:empty?)]
      end
  end
end
